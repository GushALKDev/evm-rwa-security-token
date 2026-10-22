import type { Address } from 'viem'
import type { Deployment, Seed } from '../config/deployment'
import type { AccountExtras, LiveData, PartyData, StaticData } from '../hooks/useTokenData'
import { shortAddress } from './format'
import { freeBalance, isVerified, unlocksAt, type GateState, type ModuleKind } from './gate'

export interface AccountView {
  address: Address
  party: PartyData
  extras: AccountExtras | undefined
  /** At the latest block's timestamp, which is what the next call's simulation sees */
  verified: boolean
  free: bigint
  unlocksAt: bigint | null
  locked: boolean
}

export interface TokenModel {
  deployment: Deployment
  static: StaticData
  live: LiveData
  gate: GateState
  /** The latest block's timestamp: every time-dependent rule is evaluated here */
  chainTime: bigint
  /** The visitor's clock, for countdowns only */
  now: bigint
  parties: Map<string, PartyData>
  account: AccountView | null
}

export function moduleKind(d: Deployment, address: Address): ModuleKind {
  const a = address.toLowerCase()
  if (a === d.maxHolders.toLowerCase()) return 'maxHolders'
  if (a === d.countryRestriction.toLowerCase()) return 'country'
  if (a === d.lockup.toLowerCase()) return 'lockup'
  if (a === d.distributor.toLowerCase()) return 'distributor'
  return 'unknown'
}

export function gateState(d: Deployment, live: LiveData, restricted: ReadonlyMap<number, boolean>): GateState {
  return {
    paused: live.paused,
    holderCount: live.holderCount,
    maxHolders: live.maxHolders,
    lockupPeriod: live.lockupPeriod,
    restricted,
    modules: live.modules.map((address) => ({ address, kind: moduleKind(d, address) })),
  }
}

export function buildModel(
  d: Deployment,
  st: StaticData,
  live: LiveData,
  partyList: PartyData[],
  restricted: ReadonlyMap<number, boolean>,
  extras: AccountExtras | undefined,
  account: Address | undefined,
  chainTime: bigint,
  now: bigint,
): TokenModel {
  const parties = new Map(partyList.map((p) => [p.address.toLowerCase(), p]))
  const gate = gateState(d, live, restricted)
  let accountView: AccountView | null = null
  const own = account ? parties.get(account.toLowerCase()) : undefined
  if (account && own) {
    const end = unlocksAt(own, live.lockupPeriod)
    accountView = {
      address: account,
      party: own,
      extras,
      verified: isVerified(own, chainTime),
      free: freeBalance(own),
      unlocksAt: end,
      locked: end !== null && chainTime < end,
    }
  }
  return { deployment: d, static: st, live, gate, chainTime, now, parties, account: accountView }
}

export function seedOf(d: Deployment, address: string): Seed | undefined {
  return d.seeds.find((s) => s.address.toLowerCase() === address.toLowerCase())
}

/** Names an address in a sentence: "your wallet", a seeded wallet's label, or a short address. */
export function labelOf(d: Deployment, account: Address | undefined, address: string): string {
  if (account && address.toLowerCase() === account.toLowerCase()) return 'your wallet'
  const seed = seedOf(d, address)
  return seed ? `the ${seed.label.charAt(0).toLowerCase()}${seed.label.slice(1)} (a seeded wallet)` : shortAddress(address)
}
