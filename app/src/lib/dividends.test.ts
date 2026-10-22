import { describe, expect, it } from 'vitest'
import {
  MAGNITUDE,
  ONE_TOKEN,
  accumulated,
  claimable,
  correctionAfterMint,
  correctionSlot,
  correctionsAfterTransfer,
  couponAmount,
  couponPreview,
  decodeInt256,
  depositEffect,
  perToken,
} from './dividends'
import { formatEurc, formatTokenCount, formatTokens, parseAmount, toInput } from './format'

describe('the accumulator', () => {
  it('pays a sole holder the deposit, rounded down by the scaling', () => {
    // 5,000 EURC over 1,000 tokens: 5e9 * 2^128 / 1e21 is not a whole number, so the accumulator floors it and the
    // holder is owed one unit less, the direction that keeps the distributor solvent.
    const supply = 1_000n * ONE_TOKEN
    const { dividendsPerShare, residue } = depositEffect(0n, 0n, supply, 5_000_000_000n)
    expect(accumulated(supply, dividendsPerShare, 0n)).toBe(4_999_999_999n)
    expect(residue).toBeGreaterThan(0n)
    expect(perToken(dividendsPerShare)).toBe(4_999_999n)
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
    const { dividendsPerShare: dps } = depositEffect(0n, 0n, 100n * ONE_TOKEN, 777_777n)
    const corr = correctionAfterMint(0n, 10n * ONE_TOKEN, dps)
    expect(accumulated(10n * ONE_TOKEN, dps, corr)).toBe(0n)

    const seller = accumulated(100n * ONE_TOKEN, dps, 0n)
    const moved = correctionsAfterTransfer(0n, corr, 40n * ONE_TOKEN, dps, false)
    expect(accumulated(60n * ONE_TOKEN, dps, moved.from)).toBe(seller)
    expect(accumulated(50n * ONE_TOKEN, dps, moved.to)).toBe(0n)
    expect(correctionsAfterTransfer(5n, 7n, ONE_TOKEN, dps, true)).toEqual({ from: 5n, to: 7n })
  })

  it('refuses a negative entitlement instead of wrapping it', () => {
    expect(() => accumulated(0n, 1n, 1n)).toThrow()
    expect(claimable(10n, 4n)).toBe(6n)
  })

  it('sizes the coupon at five EURC per whole token, rounded down', () => {
    expect(couponAmount(1_000n * ONE_TOKEN, 5_000_000n)).toBe(5_000_000_000n)
    expect(couponAmount(1_000n * ONE_TOKEN + 1n, 5_000_000n)).toBe(5_000_000_000n)
    expect(couponAmount(ONE_TOKEN / 5_000_000n - 1n, 5_000_000n)).toBe(0n)
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
  it('parses and writes back token amounts', () => {
    expect(parseAmount('1.5', 18)).toBe(1_500_000_000_000_000_000n)
    expect(parseAmount('1,000', 18)).toBe(1_000n * 10n ** 18n)
    expect(parseAmount('abc', 18)).toBeNull()
    expect(toInput(1_500_000_000_000_000_000n, 18)).toBe('1.5')
  })

  it('never shows a token amount higher than it is', () => {
    expect(formatTokens(10n ** 18n - 1n)).toBe('0.9999')
    expect(formatTokens(1n)).toBe('< 0.0001')
    expect(formatTokens(1_500n * 10n ** 18n)).toBe('1,500')
  })

  it('names one token in the singular', () => {
    expect(formatTokenCount(10n ** 18n)).toBe('1 token')
    expect(formatTokenCount(2n * 10n ** 18n)).toBe('2 tokens')
    expect(formatTokenCount(10n ** 18n / 2n)).toBe('0.5 tokens')
  })

  it('shows EURC to the cent when exact, and every unit otherwise', () => {
    expect(formatEurc(5_000_000_000n)).toBe('5,000.00')
    expect(formatEurc(12_500_000n)).toBe('12.50')
    expect(formatEurc(4_999_999n)).toBe('4.999999')
    expect(formatEurc(49_999_990n)).toBe('49.99999')
    expect(formatEurc(0n)).toBe('0.00')
  })
})

describe('the coupon preview', () => {
  // The reviewer's case: a balance read before a mint landed and a correction read after it. On one block they can
  // never disagree; the page must still not throw while rendering if they ever do.
  it('returns nothing, rather than throwing, when its inputs come from different blocks', () => {
    const minted = 10n * ONE_TOKEN
    const dps = depositEffect(0n, 0n, 1_000n * ONE_TOKEN, 5_000_000_000n).dividendsPerShare
    const mixed = {
      blockNumber: 1n,
      balance: 0n,
      supply: 1_010n * ONE_TOKEN,
      dividendsPerShare: dps,
      residue: 0n,
      correction: correctionAfterMint(0n, minted, dps),
    }
    expect(() => couponPreview(mixed, 5_000_000n)).not.toThrow()
    expect(couponPreview(mixed, 5_000_000n)).toBeNull()
  })

  it('previews the share of a holder from a consistent snapshot', () => {
    const supply = 1_000n * ONE_TOKEN
    const s = { blockNumber: 1n, balance: 10n * ONE_TOKEN, supply, dividendsPerShare: 0n, residue: 0n, correction: 0n }
    const p = couponPreview(s, 5_000_000n)!
    expect(p.amount).toBe(5_000_000_000n)
    expect(p.share).toBe(accumulated(10n * ONE_TOKEN, p.dividendsPerShareAfter, 0n))
    expect(p.earned).toBe(0n)
  })
})
