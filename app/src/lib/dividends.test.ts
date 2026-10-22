import { describe, expect, it } from 'vitest'
import {
  MAGNITUDE,
  ONE_NOTE,
  accumulated,
  claimable,
  correctionAfterMint,
  correctionSlot,
  correctionsAfterTransfer,
  couponAmount,
  decodeInt256,
  depositEffect,
  perNote,
} from './dividends'
import { formatEurc, formatNotes, parseAmount, toInput } from './format'

describe('the accumulator', () => {
  it('pays a sole holder the deposit, rounded down by the scaling', () => {
    // 5,000 EURC over 1,000 notes: 5e9 * 2^128 / 1e21 is not a whole number, so the accumulator floors it and the
    // holder is owed one unit less, the direction that keeps the distributor solvent.
    const supply = 1_000n * ONE_NOTE
    const { dividendsPerShare, residue } = depositEffect(0n, 0n, supply, 5_000_000_000n)
    expect(accumulated(supply, dividendsPerShare, 0n)).toBe(4_999_999_999n)
    expect(residue).toBeGreaterThan(0n)
    expect(perNote(dividendsPerShare)).toBe(4_999_999n)
  })

  it('carries the remainder in scaled units and never pays out more than was deposited', () => {
    // Three holders of one base unit each, three deposits of one unit of currency.
    let s = { dividendsPerShare: 0n, residue: 0n }
    for (let i = 0; i < 3; i++) s = depositEffect(s.dividendsPerShare, s.residue, 3n, 1n)
    expect(s.residue).toBeLessThan(3n)
    const each = accumulated(1n, s.dividendsPerShare, 0n)
    expect(3n * each).toBeLessThanOrEqual(3n)
    // The carry recovers what single deposits would lose: each holder ends one unit owed, the full amount.
    expect(each).toBe(1n)
  })

  it('rounds each holder down, at most one unit', () => {
    const supply = 3n
    const { dividendsPerShare } = depositEffect(0n, 0n, supply, 10n)
    expect(accumulated(1n, dividendsPerShare, 0n)).toBe(3n)
    expect(3n * accumulated(1n, dividendsPerShare, 0n)).toBeLessThanOrEqual(10n)
  })

  it('a mint earns nothing from past deposits, and a transfer moves no income', () => {
    const { dividendsPerShare: dps } = depositEffect(0n, 0n, 100n * ONE_NOTE, 777_777n)
    const corr = correctionAfterMint(0n, 10n * ONE_NOTE, dps)
    expect(accumulated(10n * ONE_NOTE, dps, corr)).toBe(0n)

    const seller = accumulated(100n * ONE_NOTE, dps, 0n)
    const moved = correctionsAfterTransfer(0n, corr, 40n * ONE_NOTE, dps, false)
    expect(accumulated(60n * ONE_NOTE, dps, moved.from)).toBe(seller)
    expect(accumulated(50n * ONE_NOTE, dps, moved.to)).toBe(0n)
    expect(correctionsAfterTransfer(5n, 7n, ONE_NOTE, dps, true)).toEqual({ from: 5n, to: 7n })
  })

  it('refuses a negative entitlement instead of wrapping it', () => {
    expect(() => accumulated(0n, 1n, 1n)).toThrow()
    expect(claimable(10n, 4n)).toBe(6n)
  })

  it('sizes the coupon at five EURC per whole note, rounded down', () => {
    expect(couponAmount(1_000n * ONE_NOTE, 5_000_000n)).toBe(5_000_000_000n)
    expect(couponAmount(1_000n * ONE_NOTE + 1n, 5_000_000n)).toBe(5_000_000_000n)
    expect(couponAmount(ONE_NOTE / 5_000_000n - 1n, 5_000_000n)).toBe(0n)
  })

  it('reads the correction slot as a signed word', () => {
    expect(decodeInt256('0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff')).toBe(-1n)
    expect(decodeInt256('0x00000000000000000000000000000000000000000000000000000000000000ff')).toBe(255n)
    expect(decodeInt256('0x0')).toBe(0n)
    expect(MAGNITUDE).toBe(2n ** 128n)
    // keccak256(abi.encode(address(0), uint256(4)))
    expect(correctionSlot('0x0000000000000000000000000000000000000000')).toBe(
      '0x17ef568e3e12ab5b9c7254a8d58478811de00f9e6eb34345acd53bf8fd09d3ec',
    )
  })
})

describe('format', () => {
  it('parses and writes back note amounts', () => {
    expect(parseAmount('1.5', 18)).toBe(1_500_000_000_000_000_000n)
    expect(parseAmount('1,000', 18)).toBe(1_000n * 10n ** 18n)
    expect(parseAmount('abc', 18)).toBeNull()
    expect(toInput(1_500_000_000_000_000_000n, 18)).toBe('1.5')
  })

  it('never shows a note amount higher than it is', () => {
    expect(formatNotes(10n ** 18n - 1n)).toBe('0.9999')
    expect(formatNotes(1n)).toBe('< 0.0001')
    expect(formatNotes(1_500n * 10n ** 18n)).toBe('1,500')
  })

  it('shows EURC to the cent when exact, and every unit otherwise', () => {
    expect(formatEurc(5_000_000_000n)).toBe('5,000.00')
    expect(formatEurc(12_500_000n)).toBe('12.50')
    expect(formatEurc(4_999_999n)).toBe('4.999999')
    expect(formatEurc(49_999_990n)).toBe('49.99999')
    expect(formatEurc(0n)).toBe('0.00')
  })
})
