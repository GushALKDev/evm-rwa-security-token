import { isAddress, zeroAddress, type Address } from 'viem'

/** An address typed into the gate: the address, a reason it cannot be used, or nothing yet. */
export type TypedAddress = { address: Address } | { error: string } | null

export function parseTypedAddress(input: string): TypedAddress {
  const s = input.trim()
  if (s === '') return null
  if (!isAddress(s)) return { error: 'Not an address.' }
  // The token refuses it before the gate runs, and canTransfer reads it as a sender as a mint (New issue covers that).
  if (s.toLowerCase() === zeroAddress) return { error: 'The zero address cannot hold or send notes; for a mint, pick New issue.' }
  return { address: s as Address }
}
