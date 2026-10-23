// Where each check of the gate is written, at the commit the Base Sepolia contracts were deployed from. Deployed code
// cannot change, so the links are pinned to that commit rather than to a branch that moves on. scripts/source.test.ts
// checks every line against that commit.
import type { CheckKey, ModuleKind } from '../lib/gate'
import { links } from './chain'

export const sourceCommit = '5ddf541d9b0b2146583e5f9ae9181f9c905423b1'

export interface SourceAnchor {
  /** From the repository root */
  path: string
  from: number
  to?: number
}

const TOKEN = 'src/SecurityToken.sol'

/** The token's own checks: the pause in _update, the rest in _checkTransfer. */
export const checkSource: Record<Exclude<CheckKey, 'module'>, SourceAnchor> = {
  pause: { path: TOKEN, from: 276 },
  recipientVerified: { path: TOKEN, from: 324 },
  recipientFrozen: { path: TOKEN, from: 325 },
  senderVerified: { path: TOKEN, from: 332 },
  senderFrozen: { path: TOKEN, from: 333 },
  unfrozen: { path: TOKEN, from: 335 },
}

/** Each module's moduleCheck. */
export const moduleSource: Partial<Record<ModuleKind, SourceAnchor>> = {
  maxHolders: { path: 'src/compliance/modules/MaxHoldersModule.sol', from: 123, to: 139 },
  country: { path: 'src/compliance/modules/CountryRestrictionModule.sol', from: 96, to: 104 },
  lockup: { path: 'src/compliance/modules/LockupModule.sol', from: 125, to: 138 },
  distributor: { path: 'src/compliance/modules/DividendDistributor.sol', from: 233, to: 235 },
}

/** ModularCompliance.canTransfer: the loop over the modules that stops at the first refusal. */
export const engineSource: SourceAnchor = { path: 'src/compliance/ModularCompliance.sol', from: 177, to: 184 }

export function sourceUrl(a: SourceAnchor): string {
  return `${links.repo}/blob/${sourceCommit}/${a.path}#L${a.from}${a.to ? `-L${a.to}` : ''}`
}
