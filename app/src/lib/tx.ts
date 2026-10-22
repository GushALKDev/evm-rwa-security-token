// The steps of one write: prepare (simulate and estimate), send, and wait for the outcome. Kept apart from the
// hook so scripts/tx.test.ts can run them against a local chain.
import { encodeFunctionData, type Abi, type Address, type Hash, type ReplacementReturnType, type TransactionReceipt } from 'viem'
import type { Config } from 'wagmi'
import { estimateGas, getPublicClient, simulateContract, writeContract } from 'wagmi/actions'
import { withGasMargin } from './gas'

export interface ContractCall {
  address: Address
  abi: Abi | readonly unknown[]
  functionName: string
  args?: readonly unknown[]
}

export type Outcome =
  | { kind: 'success'; receipt: TransactionReceipt }
  | { kind: 'reverted'; receipt: TransactionReceipt }
  | { kind: 'cancelled' }
  | { kind: 'replaced'; hash: Hash }
  | { kind: 'unknown' }

/**
 * Simulates and estimates a call on the app's chain: everything before the wallet asks for a signature. Every step
 * names the chain, since without it wagmi uses whichever chain the wallet is on.
 */
export async function prepareCall(config: Config, chainId: number, call: ContractCall, account: Address) {
  // Simulating first surfaces a revert, decoded, before the wallet asks for a signature.
  const { request } = await simulateContract(config, { ...call, account, chainId } as never)
  const estimate = await estimateGas(config, {
    account,
    chainId,
    to: call.address,
    data: encodeFunctionData({ abi: call.abi as Abi, functionName: call.functionName, args: call.args as unknown[] }),
  } as never)
  return { request, gas: withGasMargin(estimate) }
}

/**
 * Asks the wallet to sign and send a prepared call. With the chain named, wagmi refuses before the signature when
 * the wallet is on another network; without it, the call would be signed and sent on that network.
 */
export async function sendCall(config: Config, chainId: number, request: unknown, gas: bigint): Promise<Hash> {
  return writeContract(config, { ...(request as object), gas, chainId } as never)
}

/**
 * Waits for a sent transaction on the app's chain and says what happened to it. Reads the receipt through viem's
 * public client: wagmi's waitForTransactionReceipt throws on a reverted receipt, which would read as an unknown
 * outcome. A transaction the wallet replaced resolves with the replacement's receipt, so the replacement is checked
 * first: a cancellation is not the call succeeding.
 */
export async function waitForOutcome(config: Config, chainId: number, hash: Hash, timeoutMs: number): Promise<Outcome> {
  const client = getPublicClient(config, { chainId } as never)
  if (!client) return { kind: 'unknown' }
  let replacement: ReplacementReturnType | undefined
  try {
    const receipt = await client.waitForTransactionReceipt({
      hash,
      timeout: timeoutMs,
      onReplaced: (r) => {
        replacement = r
      },
    })
    if (replacement?.reason === 'cancelled') return { kind: 'cancelled' }
    if (replacement?.reason === 'replaced') return { kind: 'replaced', hash: replacement.transaction.hash }
    // A repriced transaction is the same call with a new fee, so its receipt is this call's outcome.
    return receipt.status === 'success' ? { kind: 'success', receipt } : { kind: 'reverted', receipt }
  } catch {
    return { kind: 'unknown' }
  }
}
