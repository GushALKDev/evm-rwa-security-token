import { useQueryClient } from '@tanstack/react-query'
import { useCallback, useState } from 'react'
import type { Abi, Address } from 'viem'
import { useConnection } from 'wagmi'
import { estimateGas, simulateContract, waitForTransactionReceipt, writeContract } from 'wagmi/actions'
import { BaseError, ContractFunctionRevertedError, encodeFunctionData, ExecutionRevertedError } from 'viem'
import { explorerTx } from '../config/chain'
import { describeError, LANDED_REVERT, type ErrorContext } from '../lib/errors'
import { withGasMargin } from '../lib/gas'
import { wagmiConfig } from '../wagmi'
import { useToasts } from './useToasts'

export interface ContractCall {
  address: Address
  abi: Abi | readonly unknown[]
  functionName: string
  args?: readonly unknown[]
}

/** Tries, and the pause between them, for a call that depends on a transaction just mined while the RPC catches up. */
const CATCH_UP_TRIES = 5
const CATCH_UP_MS = 2_000

const isRevert = (err: unknown) =>
  err instanceof BaseError &&
  !!err.walk((e) => e instanceof ContractFunctionRevertedError || e instanceof ExecutionRevertedError)

/** Builds, simulates and estimates a call: everything before the wallet asks for a signature. */
async function prepare(call: ContractCall, account: Address) {
  // Simulating first surfaces a revert, decoded, before the wallet asks for a signature.
  const { request } = await simulateContract(wagmiConfig, { ...call, account } as never)
  const estimate = await estimateGas(wagmiConfig, {
    account,
    to: call.address,
    data: encodeFunctionData({ abi: call.abi as Abi, functionName: call.functionName, args: call.args as unknown[] }),
  })
  return { request, gas: withGasMargin(estimate) }
}

/** Simulates, sends and confirms one call at a time, reporting each step in a toast. */
export function useTx(errorContext: ErrorContext) {
  const { address } = useConnection()
  const toasts = useToasts()
  const queryClient = useQueryClient()
  const [busy, setBusy] = useState<string | null>(null)

  const run = useCallback(
    async (label: string, done: string, call: ContractCall, opts: { afterPrevious?: boolean } = {}): Promise<boolean> => {
      if (!address) return false
      setBusy(label)
      const id = toasts.push({ tone: 'pending', title: label, body: 'Checking the call against the chain…' })
      try {
        // A public RPC spreads requests over several nodes, so a call right after another one (claiming notes
        // right after onboarding) can reach a node that has not imported that block yet and revert on the old
        // state. Such a call retries a revert for a few blocks before reporting it.
        let prepared
        for (let attempt = 1; !prepared; attempt++) {
          try {
            prepared = await prepare(call, address)
          } catch (err) {
            if (!opts.afterPrevious || attempt >= CATCH_UP_TRIES || !isRevert(err)) throw err
            await new Promise((r) => setTimeout(r, CATCH_UP_MS))
          }
        }
        const { request, gas } = prepared
        toasts.update(id, { body: 'Confirm it in your wallet.' })
        const hash = await writeContract(wagmiConfig, { ...(request as object), gas } as never)
        toasts.update(id, { body: 'Waiting for the block…', href: explorerTx(hash) })
        let receipt
        try {
          receipt = await waitForTransactionReceipt(wagmiConfig, { hash })
        } catch {
          // The transaction was sent, but its outcome could not be read: do not guess either way.
          toasts.update(id, {
            tone: 'error',
            title: `${label}: outcome unknown`,
            body: 'The transaction was sent but its result could not be read from the RPC. Check it on the explorer before trying again.',
          })
          await queryClient.invalidateQueries()
          return false
        }
        if (receipt.status !== 'success') throw new Error(LANDED_REVERT)
        toasts.update(id, { tone: 'success', title: done, body: undefined })
        await queryClient.invalidateQueries()
        return true
      } catch (err) {
        console.error(err)
        toasts.update(id, { tone: 'error', title: `${label} failed`, body: describeError(err, errorContext) })
        return false
      } finally {
        setBusy(null)
      }
    },
    [address, toasts, queryClient, errorContext],
  )

  return { run, busy }
}
