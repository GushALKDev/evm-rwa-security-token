import { zeroAddress, zeroHash, type Address } from 'viem'
import { describe, expect, it } from 'vitest'
import { evaluateGate, holderCountAfter, identityWhy, lockupEffect, moduleCheck, senderBlock, type GateState, type PartyState } from './gate'

const NOW = 1_800_000_000n
const TOKEN = 10n ** 18n

const party = (address: Address, over: Partial<PartyState> = {}): PartyState => ({
  address,
  verified: true,
  kycExpiry: NOW + 86_400n,
  country: 724,
  investorId: '0x1111111111111111111111111111111111111111111111111111111111111111',
  balance: 10n * TOKEN,
  frozen: false,
  frozenTokens: 0n,
  lockStart: NOW - 600n,
  ...over,
})

const alice = party('0x00000000000000000000000000000000000000a1')
const bob = party('0x00000000000000000000000000000000000000b2', { balance: 5n * TOKEN })

// The deployed order: holder cap, jurisdiction, lockup, distributor.
const state = (over: Partial<GateState> = {}): GateState => ({
  paused: false,
  holderCount: 6n,
  maxHolders: 499n,
  lockupPeriod: 300n,
  restricted: new Map([
    [724, false],
    [364, true],
  ]),
  modules: [
    { address: '0x0000000000000000000000000000000000000001', kind: 'maxHolders' },
    { address: '0x0000000000000000000000000000000000000002', kind: 'country' },
    { address: '0x0000000000000000000000000000000000000003', kind: 'lockup' },
    { address: '0x0000000000000000000000000000000000000004', kind: 'distributor' },
  ],
  ...over,
})

describe('evaluateGate', () => {
  it('clears a transfer between two settled holders, every check passing', () => {
    const r = evaluateGate(state(), alice, bob, TOKEN, NOW)
    expect(r.ok).toBe(true)
    expect(r.revert).toBeNull()
    expect(r.checks.map((c) => c.outcome)).toEqual(Array(10).fill('pass'))
  })

  it('runs the checks in the contract order', () => {
    const r = evaluateGate(state(), alice, bob, TOKEN, NOW)
    expect(r.checks.map((c) => c.module?.kind ?? c.key)).toEqual([
      'pause',
      'recipientVerified',
      'recipientFrozen',
      'senderVerified',
      'senderFrozen',
      'unfrozen',
      'maxHolders',
      'country',
      'lockup',
      'distributor',
    ])
  })

  it('stops at the pause before anything else', () => {
    const r = evaluateGate(state({ paused: true }), alice, party(bob.address, { verified: false }), TOKEN, NOW)
    expect(r.stoppedAt).toBe(0)
    expect(r.revert).toEqual({ name: 'EnforcedPause', args: [] })
    expect(r.checks.slice(1).every((c) => c.outcome === 'unreached')).toBe(true)
  })

  it('checks the recipient before the sender', () => {
    const r = evaluateGate(state(), party(alice.address, { frozen: true }), party(bob.address, { verified: false, investorId: zeroHash }), TOKEN, NOW)
    expect(r.revert).toEqual({ name: 'RecipientNotVerified', args: [bob.address] })
  })

  it('treats an expiry equal to the block timestamp as lapsed', () => {
    const lapsed = party(bob.address, { kycExpiry: NOW })
    expect(identityWhy(lapsed, NOW)).toBe('lapsed')
    expect(evaluateGate(state(), alice, lapsed, TOKEN, NOW).revert?.name).toBe('RecipientNotVerified')
    expect(identityWhy(lapsed, NOW - 1n)).toBe('verified')
  })

  it('tells a removed identity from one never registered', () => {
    expect(identityWhy(party(bob.address, { verified: false, kycExpiry: 0n }), NOW)).toBe('removed')
    expect(identityWhy(party(bob.address, { verified: false, kycExpiry: 0n, investorId: zeroHash }), NOW)).toBe('neverRegistered')
  })

  it('reports a frozen recipient, then a frozen sender', () => {
    expect(evaluateGate(state(), alice, party(bob.address, { frozen: true }), TOKEN, NOW).revert).toEqual({
      name: 'RecipientAddressFrozen',
      args: [bob.address],
    })
    expect(evaluateGate(state(), party(alice.address, { frozen: true }), bob, TOKEN, NOW).revert).toEqual({
      name: 'SenderAddressFrozen',
      args: [alice.address],
    })
  })

  it('lets only the unfrozen part move, with the free amount in the revert', () => {
    const partly = party(alice.address, { frozenTokens: 4n * TOKEN })
    expect(evaluateGate(state(), partly, bob, 6n * TOKEN, NOW).ok).toBe(true)
    expect(evaluateGate(state(), partly, bob, 6n * TOKEN + 1n, NOW).revert).toEqual({
      name: 'InsufficientUnfrozenBalance',
      args: [alice.address, 6n * TOKEN, 6n * TOKEN + 1n],
    })
  })

  it('reports any module rejection as ComplianceCheckFailed and names the module that stopped it', () => {
    const r = evaluateGate(state(), alice, party(bob.address, { country: 364 }), TOKEN, NOW)
    expect(r.revert).toEqual({ name: 'ComplianceCheckFailed', args: [alice.address, bob.address, TOKEN] })
    expect(r.checks[r.stoppedAt!].module?.kind).toBe('country')
    expect(r.checks[r.stoppedAt! + 1].outcome).toBe('unreached')
  })

  it('skips the sender checks on a mint and reports the zero address as sender', () => {
    const r = evaluateGate(state(), null, party(bob.address, { country: 364 }), TOKEN, NOW)
    expect(r.checks.slice(3, 6).map((c) => c.outcome)).toEqual(['skipped', 'skipped', 'skipped'])
    expect(r.revert).toEqual({ name: 'ComplianceCheckFailed', args: [zeroAddress, bob.address, TOKEN] })
  })

  it('leaves a decision it cannot mirror open', () => {
    const s = state({ modules: [{ address: '0x0000000000000000000000000000000000000009', kind: 'unknown' }] })
    const r = evaluateGate(s, alice, bob, TOKEN, NOW)
    expect(r.ok).toBeNull()
    expect(r.revert).toBeNull()
  })
})

describe('moduleCheck', () => {
  const cap = state({ holderCount: 499n })

  it('holder cap: blocks only a new holder at the cap', () => {
    const newcomer = party(bob.address, { balance: 0n })
    expect(moduleCheck('maxHolders', cap, alice, newcomer, TOKEN, NOW)).toEqual({ pass: false, why: 'full' })
    expect(moduleCheck('maxHolders', cap, alice, bob, TOKEN, NOW)).toEqual({ pass: true, why: 'alreadyHolds' })
    // A sender emptying out is replaced by the newcomer, but a mint never offsets.
    expect(moduleCheck('maxHolders', cap, alice, newcomer, alice.balance, NOW)).toEqual({ pass: true, why: 'replaces' })
    expect(moduleCheck('maxHolders', cap, null, newcomer, TOKEN, NOW)).toEqual({ pass: false, why: 'full' })
    expect(moduleCheck('maxHolders', cap, alice, newcomer, 0n, NOW)).toEqual({ pass: true, why: 'zeroAmount' })
  })

  it('lockup: unlocks at exactly start plus period', () => {
    const locked = party(alice.address, { lockStart: NOW - 299n })
    expect(moduleCheck('lockup', state(), locked, bob, TOKEN, NOW).pass).toBe(false)
    expect(moduleCheck('lockup', state(), party(alice.address, { lockStart: NOW - 300n }), bob, TOKEN, NOW).pass).toBe(true)
    expect(moduleCheck('lockup', state(), party(alice.address, { lockStart: 0n }), bob, TOKEN, NOW)).toEqual({ pass: true, why: 'noClock' })
    expect(moduleCheck('lockup', state(), locked, bob, 0n, NOW).pass).toBe(true)
  })

  it('jurisdiction: reads the recipient, never the sender', () => {
    expect(moduleCheck('country', state(), party(alice.address, { country: 364 }), bob, TOKEN, NOW).pass).toBe(true)
    expect(moduleCheck('country', state(), alice, party(bob.address, { country: 999 }), TOKEN, NOW)).toEqual({ pass: null, why: 'notMirrored' })
  })
})

describe('effects', () => {
  const empty = party('0x00000000000000000000000000000000000000c3', { balance: 0n, lockStart: 0n })

  it('counts a holder joining, leaving, and one replacing another', () => {
    expect(holderCountAfter(6n, alice, empty, TOKEN)).toBe(7n)
    expect(holderCountAfter(6n, alice, bob, alice.balance)).toBe(5n)
    expect(holderCountAfter(6n, alice, empty, alice.balance)).toBe(6n)
    expect(holderCountAfter(6n, alice, alice, alice.balance)).toBe(6n)
    expect(holderCountAfter(6n, null, empty, TOKEN)).toBe(7n)
    expect(holderCountAfter(6n, alice, empty, 0n)).toBe(6n)
  })

  it('starts a clock only for a recipient coming from zero, and clears an exiting sender', () => {
    expect(lockupEffect(alice, empty, TOKEN)).toEqual({ recipientStarts: true, senderCleared: false })
    expect(lockupEffect(alice, bob, alice.balance)).toEqual({ recipientStarts: false, senderCleared: true })
    expect(lockupEffect(alice, alice, alice.balance)).toEqual({ recipientStarts: false, senderCleared: false })
    expect(lockupEffect(null, empty, TOKEN)).toEqual({ recipientStarts: true, senderCleared: false })
  })
})

describe('senderBlock', () => {
  // The position card says whether your tokens can move. Only the lockup used to count, so a lapsed, removed or
  // frozen wallet, or a paused token, read as free to send.
  it('names every sender-side stop, in the gate order', () => {
    const free = party(alice.address, { lockStart: NOW - 600n })
    expect(senderBlock(state(), free, NOW)).toBeNull()
    expect(senderBlock(state({ paused: true }), free, NOW)).toBe('paused')
    expect(senderBlock(state(), party(alice.address, { kycExpiry: NOW }), NOW)).toBe('unverified')
    expect(senderBlock(state(), party(alice.address, { verified: false }), NOW)).toBe('unverified')
    expect(senderBlock(state(), party(alice.address, { frozen: true }), NOW)).toBe('frozen')
    expect(senderBlock(state(), party(alice.address, { lockStart: NOW - 10n }), NOW)).toBe('locked')
  })
})
