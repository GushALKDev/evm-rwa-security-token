/**
 * Gas on top of the node's estimate. A transfer to a wallet that holds nothing writes its balance, its lockup clock
 * and its dividend correction from zero and moves the holder count: about 68,000 gas more than the same transfer to
 * an existing holder. The node estimates against the latest block, so if the recipient empties its wallet before
 * the call lands, a 25% margin alone falls short. scripts/parity.test.ts replays that case on a local deployment.
 */
export const GAS_MARGIN_FIXED = 80_000n

export function withGasMargin(estimate: bigint): bigint {
  return (estimate * 125n) / 100n + GAS_MARGIN_FIXED
}
