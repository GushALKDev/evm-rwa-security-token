import { describe, expect, it } from 'vitest'
import { solidityAmount } from './format'

describe('solidityAmount', () => {
  it('writes whole amounts in the scale of their decimals and anything else digit by digit', () => {
    expect(solidityAmount(10n * 10n ** 18n, 18)).toBe('10e18')
    expect(solidityAmount(5_000_000_000n, 6)).toBe('5000e6')
    expect(solidityAmount(1_500_000_000_000_000_000n, 18)).toBe('1500000000000000000')
    expect(solidityAmount(1n, 18)).toBe('1')
    expect(solidityAmount(0n, 18)).toBe('0')
  })
})
