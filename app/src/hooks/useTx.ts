import { useQueryClient } from '@tanstack/react-query'
import { useCallback, useState } from 'react'
import { BaseError, ContractFunctionRevertedError, ExecutionRevertedError } from 'viem'
import { useConnection } from 'wagmi'
import { chain, explorerTx } from '../config/chain'
import { describeError, LANDED_REVERT, type ErrorContext } from '../lib/errors'
import { prepareCall, sendCall, waitForOutcome, type ContractCall } from '../lib/tx'
import { wagmiConfig } from '../wagmi'
import { useToasts } from './useToasts'

/** Tries, and the pause between them, for a call that depends on a transaction just mined while the RPC catches up. */
const CATCH_UP_TRIES = 5
const CATCH_UP_MS = 2_000

/** How long to wait for a receipt before reporting the outcome as unknown. */
const RECEIPT_TIMEOUT_MS = 180_000

const isRevert = (err: unknown) =>
  err instanceof BaseError &&
  !!err.walk((e) => e instanceof ContractFunctionRevertedError || e instanceof ExecutionRevertedError)

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
            prepared = await prepareCall(wagmiConfig, chain.id, call, address)
          } catch (err) {
            if (!opts.afterPrevious || attempt >= CATCH_UP_TRIES || !isRevert(err)) throw err
            await new Promise((r) => setTimeout(r, CATCH_UP_MS))
          }
        }
        toasts.update(id, { body: 'Confirm it in your wallet.' })
        const hash = await sendCall(wagmiConfig, chain.id, prepared.request, prepared.gas)
        toasts.update(id, { body: 'Waiting for the block…', href: explorerTx(hash) })
        const outcome = await waitForOutcome(wagmiConfig, chain.id, hash, RECEIPT_TIMEOUT_MS)
        await queryClient.invalidateQueries()
        switch (outcome.kind) {
          case 'success':
            toasts.update(id, { tone: 'success', title: done, body: undefined })
            return true
          case 'reverted':
            toasts.update(id, { tone: 'error', title: `${label} failed`, body: LANDED_REVERT })
            return false
          case 'cancelled':
            toasts.update(id, {
              tone: 'error',
              title: `${label} cancelled`,
              body: 'Your wallet replaced the transaction with a cancellation, so nothing changed.',
            })
            return false
          case 'replaced':
            toasts.update(id, {
              tone: 'error',
              title: `${label}: replaced`,
              body: 'Your wallet replaced the transaction with a different one. Check it on the explorer before trying again.',
              href: explorerTx(outcome.hash),
            })
            return false
          case 'unknown':
            // The transaction was sent, but its outcome could not be read: do not guess either way.
            toasts.update(id, {
              tone: 'error',
              title: `${label}: outcome unknown`,
              body: 'The transaction was sent but its result could not be read from the RPC. Check it on the explorer before trying again.',
            })
            return false
        }
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
