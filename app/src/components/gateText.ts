// Sentences for the gate's checks, from the mirror's structured reasons and the live values behind them.
import { countryLabel } from '../lib/countries'
import { formatDate, formatDuration, formatNoteCount, formatNotes, formatTimestamp, shortAddress } from '../lib/format'
import { freeBalance, unlocksAt, type Check, type PartyState, type Revert } from '../lib/gate'
import type { TokenModel } from '../lib/model'

export interface CheckText {
  title: string
  /** The contract that runs the check, for module rows */
  contract?: string
  detail: string
}

const moduleTitles = {
  maxHolders: 'Holder cap',
  country: 'Jurisdiction',
  lockup: 'Lockup',
  distributor: 'Dividends',
  unknown: 'Module',
} as const

export function checkText(
  c: Check,
  model: TokenModel,
  from: PartyState | null,
  to: PartyState,
  amount: bigint,
): CheckText {
  const title = c.module
    ? moduleTitles[c.module.kind]
    : {
        pause: 'Token not paused',
        recipientVerified: 'Recipient verified',
        recipientFrozen: 'Recipient not frozen',
        senderVerified: 'Sender verified',
        senderFrozen: 'Sender not frozen',
        unfrozen: 'Free balance covers the amount',
        module: '',
      }[c.key]
  const contract = c.module
    ? (model.static.moduleNames[c.module.address.toLowerCase()] ?? shortAddress(c.module.address))
    : undefined
  if (c.outcome === 'unreached') return { title, contract, detail: 'Not evaluated: the contract stops at the first failure.' }

  const party = c.key === 'recipientVerified' || c.key === 'recipientFrozen' ? to : from
  const g = model.gate
  const count = `${g.holderCount.toString()} of ${g.maxHolders.toString()}`
  let detail: string
  switch (c.why) {
    case 'open':
      detail = 'Transfers are open.'
      break
    case 'paused':
      detail = 'The agent has paused the token.'
      break
    case 'verified':
      detail = `KYC valid until ${formatDate(party!.kycExpiry)}, resident in ${countryLabel(party!.country)}.`
      break
    case 'lapsed':
      detail = `Its KYC lapsed on ${formatTimestamp(party!.kycExpiry)}.`
      break
    case 'removed':
      detail = 'The agent removed its identity. The investor id is kept, and so are any notes.'
      break
    case 'neverRegistered':
      detail = 'Not in the identity registry.'
      break
    case 'notFrozen':
      detail = 'Not frozen.'
      break
    case 'frozen':
      detail = 'The agent froze this wallet.'
      break
    case 'mint':
      detail =
        c.key === 'module'
          ? 'A new issue is an acquisition, so there is nothing to lock.'
          : 'Skipped: a new issue has no sender.'
      break
    case 'enough':
    case 'notEnough': {
      const p = from!
      const frozen = p.frozenTokens > 0n ? `, ${formatNotes(p.frozenTokens)} frozen` : ''
      detail =
        c.why === 'enough'
          ? `${formatNotes(freeBalance(p))} of ${formatNoteCount(p.balance)} free${frozen}.`
          : `Only ${formatNotes(freeBalance(p))} of ${formatNoteCount(p.balance)} free${frozen}; ${formatNotes(amount)} requested.`
      break
    }
    case 'zeroAmount':
      detail = 'A zero amount moves no value, so the module lets it through.'
      break
    case 'alreadyHolds':
      detail = `The recipient already holds notes, so the count stays at ${count}.`
      break
    case 'replaces':
      detail = `The sender empties out, so one holder replaces another: ${count}.`
      break
    case 'roomLeft':
      detail = `A new holder: ${count}, room for ${(g.maxHolders - g.holderCount).toString()} more.`
      break
    case 'full':
      detail = `A new holder, and the register is full: ${count}.`
      break
    case 'notRestricted':
      detail = `${countryLabel(to.country)} is not restricted.`
      break
    case 'restricted':
      detail = `${countryLabel(to.country)} is restricted on this deployment.`
      break
    case 'noClock':
      detail = 'The sender has no lockup clock.'
      break
    case 'unlocked':
      detail = `The sender's lockup ended on ${formatTimestamp(unlocksAt(from!, g.lockupPeriod)!)}.`
      break
    case 'locked': {
      const end = unlocksAt(from!, g.lockupPeriod)!
      const left = Number(end - model.now)
      detail = `The sender is locked until ${formatTimestamp(end)}${left > 0 ? `, ${formatDuration(left)} from now` : ''}.`
      break
    }
    case 'observer':
      detail = 'Never blocks: it watches transfers to account income.'
      break
    case 'notMirrored':
      detail = 'This page does not mirror this module; the contract answer below decides.'
      break
  }
  return { title, contract, detail }
}

/** The revert as the contract would raise it, with short addresses. */
export function revertText(r: Revert): string {
  const arg = (x: unknown) =>
    typeof x === 'string' ? shortAddress(x) : typeof x === 'bigint' ? x.toString() : String(x)
  return `${r.name}(${r.args.map(arg).join(', ')})`
}
