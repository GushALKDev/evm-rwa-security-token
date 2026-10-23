// The gate's cases: one per seeded wallet, pairing it with another so the gate shows that wallet's outcome.
// scripts/parity.test.ts checks on a local deployment that each case stops where its comment says.
import type { SeedKey } from '../config/deployment'
import { ONE_TOKEN } from './dividends'

export interface Scenario {
  from: SeedKey
  to: SeedKey
  /** One token, or the sender's whole balance: a partial freeze only stops what it covers */
  amount: 'one' | 'balance'
}

export const scenarios: Record<SeedKey, Scenario> = {
  // Clears every check.
  settled: { from: 'settled', to: 'partlyFrozen', amount: 'one' },
  // Stops at the recipient's identity: never registered.
  unverified: { from: 'settled', to: 'unverified', amount: 'one' },
  // Stops at the sender's identity: the KYC expiry has passed.
  lapsed: { from: 'lapsed', to: 'settled', amount: 'one' },
  // Stops at the sender's freeze.
  frozen: { from: 'frozen', to: 'settled', amount: 'one' },
  // Stops at the sender's identity: the agent removed it, and the tokens stayed.
  suspended: { from: 'suspended', to: 'settled', amount: 'one' },
  // Stops at the free balance: the frozen part cannot move.
  partlyFrozen: { from: 'partlyFrozen', to: 'settled', amount: 'balance' },
  // Stops at the jurisdiction module.
  restricted: { from: 'settled', to: 'restricted', amount: 'one' },
}

export function scenarioAmount(s: Scenario, fromBalance: bigint): bigint {
  return s.amount === 'balance' ? fromBalance : ONE_TOKEN
}
