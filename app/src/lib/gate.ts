// The transfer gate, mirrored from the contracts so the page can show every check as the contract runs it.
// SecurityToken._update checks the pause first, then _checkTransfer runs the token's own checks in a fixed order
// and, last, ModularCompliance.canTransfer asks each module in registration order. The first failure stops the
// transfer. scripts/parity.test.ts checks this file against canTransfer, every moduleCheck and the revert each
// failing transfer raises on a local deployment.
import { zeroAddress, zeroHash, type Address, type Hex } from 'viem'

/** What the gate reads about one wallet: its identity record, its token state and its lockup clock. */
export interface PartyState {
  address: Address
  /** Identity record, as stored: `verified` is the flag, not isVerified, which also checks the expiry */
  verified: boolean
  kycExpiry: bigint
  country: number
  investorId: Hex
  balance: bigint
  frozen: boolean
  frozenTokens: bigint
  /** LockupModule.lockStart: zero when the wallet has no clock */
  lockStart: bigint
}

export type ModuleKind = 'maxHolders' | 'country' | 'lockup' | 'distributor' | 'unknown'

export interface ModuleRef {
  address: Address
  kind: ModuleKind
}

export interface GateState {
  paused: boolean
  holderCount: bigint
  maxHolders: bigint
  lockupPeriod: bigint
  /** Restriction flag of every country code the page has read; a code missing here is read before evaluating */
  restricted: ReadonlyMap<number, boolean>
  /** The engine's modules, in registration order */
  modules: ModuleRef[]
}

export type CheckKey =
  | 'pause'
  | 'recipientVerified'
  | 'recipientFrozen'
  | 'senderVerified'
  | 'senderFrozen'
  | 'unfrozen'
  | 'module'

/** Why a check came out as it did. The interface turns these into sentences with the live values. */
export type Why =
  | 'open'
  | 'paused'
  | 'verified'
  | 'lapsed'
  | 'removed'
  | 'neverRegistered'
  | 'notFrozen'
  | 'frozen'
  | 'mint'
  | 'enough'
  | 'notEnough'
  | 'zeroAmount'
  | 'alreadyHolds'
  | 'replaces'
  | 'roomLeft'
  | 'full'
  | 'notRestricted'
  | 'restricted'
  | 'noClock'
  | 'unlocked'
  | 'locked'
  | 'observer'
  | 'notMirrored'

export type Outcome = 'pass' | 'fail' | 'skipped' | 'unreached'

export interface Check {
  key: CheckKey
  module?: ModuleRef
  outcome: Outcome
  why: Why
}

export interface Revert {
  name: string
  args: readonly unknown[]
}

export interface GateResult {
  checks: Check[]
  /** True when the transfer clears every check; null when a module this page cannot mirror decides */
  ok: boolean | null
  /** Index in `checks` of the check that stops the transfer */
  stoppedAt: number | null
  /** The error SecurityToken._update reverts with, when the transfer is stopped */
  revert: Revert | null
}

/** IdentityRegistry.isVerified: the flag, and an expiry strictly after the block's timestamp. */
export function isVerified(p: Pick<PartyState, 'verified' | 'kycExpiry'>, now: bigint): boolean {
  return p.verified && p.kycExpiry > now
}

/** Why a wallet is or is not verified. A removal clears the flag but keeps the investor id; a wallet never registered has none. */
export function identityWhy(p: PartyState, now: bigint): Why {
  if (isVerified(p, now)) return 'verified'
  if (p.verified) return 'lapsed'
  if (p.investorId !== zeroHash) return 'removed'
  return 'neverRegistered'
}

/** The unfrozen part of a balance: what a normal transfer may move. */
export function freeBalance(p: Pick<PartyState, 'balance' | 'frozenTokens'>): bigint {
  return p.balance - p.frozenTokens
}

/** When the wallet's lockup ends, or null when it has no clock. LockupModule.unlocksAt. */
export function unlocksAt(p: Pick<PartyState, 'lockStart'>, lockupPeriod: bigint): bigint | null {
  return p.lockStart === 0n ? null : p.lockStart + lockupPeriod
}

/**
 * One module's moduleCheck. `from` is null for a mint. Each branch follows the module's own code, in its order.
 */
export function moduleCheck(
  kind: ModuleKind,
  state: GateState,
  from: PartyState | null,
  to: PartyState,
  amount: bigint,
  now: bigint,
): { pass: boolean | null; why: Why } {
  switch (kind) {
    case 'maxHolders':
      // MaxHoldersModule.moduleCheck: a zero amount and an existing holder never change the count, and a
      // sender emptying out in the same transfer is replaced by the recipient. Mints never offset.
      if (amount === 0n) return { pass: true, why: 'zeroAmount' }
      if (to.balance !== 0n) return { pass: true, why: 'alreadyHolds' }
      if (from !== null && from.balance === amount) return { pass: true, why: 'replaces' }
      return state.holderCount < state.maxHolders ? { pass: true, why: 'roomLeft' } : { pass: false, why: 'full' }
    case 'country': {
      // CountryRestrictionModule.moduleCheck: the recipient's country against the blocklist.
      if (amount === 0n) return { pass: true, why: 'zeroAmount' }
      const restricted = state.restricted.get(to.country)
      if (restricted === undefined) return { pass: null, why: 'notMirrored' }
      return restricted ? { pass: false, why: 'restricted' } : { pass: true, why: 'notRestricted' }
    }
    case 'lockup': {
      // LockupModule.moduleCheck: only the sender's clock matters, and a mint is an acquisition, not a disposal.
      if (amount === 0n) return { pass: true, why: 'zeroAmount' }
      if (from === null) return { pass: true, why: 'mint' }
      if (from.lockStart === 0n) return { pass: true, why: 'noClock' }
      return now >= from.lockStart + state.lockupPeriod ? { pass: true, why: 'unlocked' } : { pass: false, why: 'locked' }
    }
    case 'distributor':
      // DividendDistributor.moduleCheck always permits: it observes transfers to account income.
      return { pass: true, why: 'observer' }
    default:
      return { pass: null, why: 'notMirrored' }
  }
}

/**
 * The gate for a transfer from `from` to `to` (a mint when `from` is null), at the block timestamp `now`.
 * Pass the latest block's timestamp: it is what the simulation of the call sees.
 */
export function evaluateGate(
  state: GateState,
  from: PartyState | null,
  to: PartyState,
  amount: bigint,
  now: bigint,
): GateResult {
  const checks: Check[] = []
  let stoppedAt: number | null = null
  let undecided = false

  const record = (key: CheckKey, pass: boolean | null, why: Why, module?: ModuleRef) => {
    if (stoppedAt !== null || undecided) {
      checks.push({ key, module, outcome: 'unreached', why })
      return
    }
    if (pass === null) {
      undecided = true
      checks.push({ key, module, outcome: 'unreached', why })
      return
    }
    checks.push({ key, module, outcome: pass ? 'pass' : 'fail', why })
    if (!pass) stoppedAt = checks.length - 1
  }

  // _update reverts with EnforcedPause before the gate runs (only forced recovery is exempt).
  record('pause', !state.paused, state.paused ? 'paused' : 'open')

  // _checkTransfer: the recipient, then the sender, then the engine.
  record('recipientVerified', isVerified(to, now), identityWhy(to, now))
  record('recipientFrozen', !to.frozen, to.frozen ? 'frozen' : 'notFrozen')
  if (from === null) {
    // A mint has no sender to verify, freeze or draw down.
    for (const key of ['senderVerified', 'senderFrozen', 'unfrozen'] as const) {
      checks.push({ key, outcome: stoppedAt !== null ? 'unreached' : 'skipped', why: 'mint' })
    }
  } else {
    record('senderVerified', isVerified(from, now), identityWhy(from, now))
    record('senderFrozen', !from.frozen, from.frozen ? 'frozen' : 'notFrozen')
    const enough = amount <= freeBalance(from)
    record('unfrozen', enough, enough ? 'enough' : 'notEnough')
  }

  // ModularCompliance.canTransfer: every module in registration order, stopping at the first rejection.
  for (const m of state.modules) {
    const r = moduleCheck(m.kind, state, from, to, amount, now)
    record('module', r.pass, r.why, m)
  }

  if (stoppedAt !== null) {
    return { checks, ok: false, stoppedAt, revert: revertFor(checks[stoppedAt].key, from, to, amount) }
  }
  return { checks, ok: undecided ? null : true, stoppedAt: null, revert: null }
}

/** SecurityToken._statusRevert, plus the pause, for the check that stopped the transfer. */
function revertFor(key: CheckKey, from: PartyState | null, to: PartyState, amount: bigint): Revert {
  switch (key) {
    case 'pause':
      return { name: 'EnforcedPause', args: [] }
    case 'recipientVerified':
      return { name: 'RecipientNotVerified', args: [to.address] }
    case 'recipientFrozen':
      return { name: 'RecipientAddressFrozen', args: [to.address] }
    case 'senderVerified':
      return { name: 'SenderNotVerified', args: [from!.address] }
    case 'senderFrozen':
      return { name: 'SenderAddressFrozen', args: [from!.address] }
    case 'unfrozen':
      return { name: 'InsufficientUnfrozenBalance', args: [from!.address, freeBalance(from!), amount] }
    case 'module':
      return { name: 'ComplianceCheckFailed', args: [from?.address ?? zeroAddress, to.address, amount] }
  }
}

/**
 * The holder count once the transfer lands: MaxHoldersModule.moduleTransferred and moduleCreated, which infer
 * from post-transfer balances whether the recipient joined and the sender left.
 */
export function holderCountAfter(count: bigint, from: PartyState | null, to: PartyState, amount: bigint): bigint {
  if (amount === 0n) return count
  if (from === null) return to.balance === 0n ? count + 1n : count
  if (from.address.toLowerCase() === to.address.toLowerCase()) return count
  const joined = to.balance === 0n
  const left = from.balance === amount
  if (joined === left) return count
  return joined ? count + 1n : count - 1n
}

/**
 * What the transfer does to the lockup clocks (LockupModule hooks): a recipient coming from zero with no clock
 * starts one when the transfer lands, and a sender exiting to zero has its clock cleared.
 */
export function lockupEffect(
  from: PartyState | null,
  to: PartyState,
  amount: bigint,
): { recipientStarts: boolean; senderCleared: boolean } {
  if (amount === 0n || (from !== null && from.address.toLowerCase() === to.address.toLowerCase())) {
    return { recipientStarts: false, senderCleared: false }
  }
  return {
    recipientStarts: to.balance === 0n && to.lockStart === 0n,
    senderCleared: from !== null && from.balance === amount && from.lockStart !== 0n,
  }
}
