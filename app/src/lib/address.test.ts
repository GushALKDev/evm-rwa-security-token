import { describe, expect, it } from 'vitest'
import { parseTypedAddress } from './address'

describe('an address typed into the gate', () => {
  it('accepts a wallet address and rejects text that is not one', () => {
    expect(parseTypedAddress(' 0x000000000000000000000000000000000000dEaD ')).toEqual({
      address: '0x000000000000000000000000000000000000dEaD',
    })
    expect(parseTypedAddress('0x1234')).toEqual({ error: 'Not an address.' })
    expect(parseTypedAddress('')).toBeNull()
  })

  // The token refuses the zero address before the gate runs (ERC20InvalidReceiver), and canTransfer reads it as a
  // sender as a mint, so the gate drawn for it would not be the contract's.
  it('rejects the zero address, which the gate does not decide', () => {
    const r = parseTypedAddress('0x0000000000000000000000000000000000000000')
    expect(r).not.toBeNull()
    expect(r && 'error' in r).toBe(true)
  })
})
