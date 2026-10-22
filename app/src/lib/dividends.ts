// The dividend accumulator, mirrored from DividendDistributor with the same scale and rounding, and the coupon
// TestnetDesk deposits. scripts/parity.test.ts checks every function here against a local deployment, to the wei.
import { encodeAbiParameters, hexToBigInt, keccak256, pad, type Address, type Hex } from 'viem'

/** DividendDistributor._MAGNITUDE: the accumulator's fixed-point scale. */
export const MAGNITUDE = 1n << 128n

/** One whole note in base units: the token has 18 decimals. */
export const ONE_NOTE = 10n ** 18n

/**
 * Storage slot of DividendDistributor._corrections, from `forge inspect DividendDistributor storageLayout`.
 * The correction has no getter, and an exact preview of a coupon's share needs its remainder modulo MAGNITUDE.
 */
export const CORRECTIONS_SLOT = 4n

/**
 * DividendDistributor.accumulated: balance times dividends per share, less the correction, descaled with a
 * floor. The floor is what keeps the distributor solvent: each holder is paid at most one unit too little.
 */
export function accumulated(balance: bigint, dividendsPerShare: bigint, correction: bigint): bigint {
  const gross = balance * dividendsPerShare - correction
  // The contract's toUint256 reverts on a negative value; reaching it means the inputs are inconsistent.
  if (gross < 0n) throw new Error('Negative entitlement: the balance, accumulator and correction disagree')
  return gross / MAGNITUDE
}

/** DividendDistributor.claimable. */
export function claimable(accumulatedAmount: bigint, withdrawn: bigint): bigint {
  return accumulatedAmount - withdrawn
}

/**
 * DividendDistributor.deposit: the amount is scaled, the carried remainder added, and the quotient by the supply
 * raises the accumulator. The remainder of that division is carried, in scaled units, into the next deposit.
 */
export function depositEffect(
  dividendsPerShare: bigint,
  residue: bigint,
  supply: bigint,
  amount: bigint,
): { dividendsPerShare: bigint; residue: bigint } {
  if (supply === 0n) throw new Error('A deposit needs a non-zero supply')
  const scaled = amount * MAGNITUDE + residue
  return { dividendsPerShare: dividendsPerShare + scaled / supply, residue: scaled % supply }
}

/** TestnetDesk.couponAmount: COUPON_PER_NOTE for every whole note outstanding, rounded down. */
export function couponAmount(supply: bigint, couponPerNote: bigint): bigint {
  return (supply * couponPerNote) / ONE_NOTE
}

/** Income paid per whole note held since the first deposit, in currency units, rounded down. */
export function perNote(dividendsPerShare: bigint): bigint {
  return (dividendsPerShare * ONE_NOTE) / MAGNITUDE
}

/**
 * The corrections after a transfer (DividendDistributor.moduleTransferred): equal and opposite, so neither
 * side's entitlement moves. A self-transfer or a zero amount changes nothing.
 */
export function correctionsAfterTransfer(
  fromCorrection: bigint,
  toCorrection: bigint,
  amount: bigint,
  dividendsPerShare: bigint,
  selfTransfer: boolean,
): { from: bigint; to: bigint } {
  if (selfTransfer || amount === 0n) return { from: fromCorrection, to: toCorrection }
  const delta = amount * dividendsPerShare
  return { from: fromCorrection - delta, to: toCorrection + delta }
}

/** The correction after a mint (DividendDistributor.moduleCreated): new notes earn nothing from past deposits. */
export function correctionAfterMint(correction: bigint, amount: bigint, dividendsPerShare: bigint): bigint {
  return correction + amount * dividendsPerShare
}

/** The slot holding `_corrections[account]`: keccak256(abi.encode(account, CORRECTIONS_SLOT)). */
export function correctionSlot(account: Address): Hex {
  return keccak256(encodeAbiParameters([{ type: 'address' }, { type: 'uint256' }], [account, CORRECTIONS_SLOT]))
}

/** Reads a raw int256 storage word as a signed bigint. */
export function decodeInt256(word: Hex | undefined): bigint {
  if (!word || word === '0x') return 0n
  return hexToBigInt(pad(word, { size: 32 }), { signed: true })
}
