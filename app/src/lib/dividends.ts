// The dividend accumulator, mirrored from DividendDistributor with the same scale and rounding, and the coupon
// TestnetDesk deposits. scripts/parity.test.ts checks every function here against a local deployment, to the wei.
import { encodeAbiParameters, erc20Abi, hexToBigInt, keccak256, pad, parseAbi, type Abi, type Address, type Hex } from 'viem'

/** DividendDistributor._MAGNITUDE: the accumulator's fixed-point scale. */
export const MAGNITUDE = 1n << 128n

/** One whole token in base units: the token has 18 decimals. */
export const ONE_TOKEN = 10n ** 18n

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

/** TestnetDesk.couponAmount: COUPON_PER_TOKEN for every whole token outstanding, rounded down. */
export function couponAmount(supply: bigint, couponPerToken: bigint): bigint {
  return (supply * couponPerToken) / ONE_TOKEN
}

/** Income paid per whole token held since the first deposit, in currency units, rounded down. */
export function perToken(dividendsPerShare: bigint): bigint {
  return (dividendsPerShare * ONE_TOKEN) / MAGNITUDE
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

/** The correction after a mint (DividendDistributor.moduleCreated): new tokens earn nothing from past deposits. */
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

/** Everything the dividends page computes from, read from one block. */
export interface AccumulatorSnapshot {
  blockNumber: bigint
  balance: bigint
  supply: bigint
  dividendsPerShare: bigint
  residue: bigint
  correction: bigint
}

export interface CouponPreview {
  amount: bigint
  dividendsPerShareAfter: bigint
  /** The account's share of the coupon, exact: what its claimable rises by when the coupon lands */
  share: bigint
  /** What the account has earned so far, at the snapshot's block */
  earned: bigint
}

/**
 * The next coupon and the account's share of it, from one snapshot. Null when the inputs disagree (a negative
 * entitlement, or no supply): read from one block they cannot, and a page rendering them must not throw if they do.
 */
export function couponPreview(s: AccumulatorSnapshot, couponPerToken: bigint): CouponPreview | null {
  if (s.supply === 0n || s.balance * s.dividendsPerShare < s.correction) return null
  const amount = couponAmount(s.supply, couponPerToken)
  const after = depositEffect(s.dividendsPerShare, s.residue, s.supply, amount)
  const earned = accumulated(s.balance, s.dividendsPerShare, s.correction)
  return {
    amount,
    dividendsPerShareAfter: after.dividendsPerShare,
    share: accumulated(s.balance, after.dividendsPerShare, s.correction) - earned,
    earned,
  }
}

interface SnapshotReader {
  getBlockNumber: () => Promise<bigint>
  readContract: (args: never) => Promise<unknown>
  getStorageAt: (args: { address: Address; slot: Hex; blockNumber: bigint }) => Promise<Hex | undefined>
}

/** Reads an account's accumulator inputs, every one at the same block, so they are consistent with each other. */
export async function readAccumulatorSnapshot(
  client: SnapshotReader,
  addresses: { token: Address; distributor: Address },
  account: Address,
): Promise<AccumulatorSnapshot> {
  const blockNumber = await client.getBlockNumber()
  const read = (address: Address, abi: Abi, functionName: string, args: readonly unknown[] = []) =>
    client.readContract({ address, abi, functionName, args, blockNumber } as never) as Promise<bigint>
  const [balance, supply, dividendsPerShare, residue, word] = await Promise.all([
    read(addresses.token, erc20Abi, 'balanceOf', [account]),
    read(addresses.token, erc20Abi, 'totalSupply'),
    read(addresses.distributor, accumulatorAbi, 'dividendsPerShare'),
    read(addresses.distributor, accumulatorAbi, 'residue'),
    client.getStorageAt({ address: addresses.distributor, slot: correctionSlot(account), blockNumber }),
  ])
  return { blockNumber, balance, supply, dividendsPerShare, residue, correction: decodeInt256(word) }
}

const accumulatorAbi = parseAbi([
  'function dividendsPerShare() view returns (uint256)',
  'function residue() view returns (uint256)',
])
