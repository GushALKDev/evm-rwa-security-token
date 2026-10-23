const groupInt = (s: string) => s.replace(/\B(?=(\d{3})+(?!\d))/g, ',')

/**
 * Formats a fixed-point bigint. Truncates toward zero, so a balance is never shown higher than it is.
 * `shown` is the number of decimals displayed; trailing zeros are kept for column alignment.
 */
export function formatFixed(value: bigint, decimals: number, shown: number): string {
  const negative = value < 0n
  const abs = negative ? -value : value
  const scale = 10n ** BigInt(decimals)
  const int = abs / scale
  let out = groupInt(int.toString())
  if (shown > 0) {
    const frac = (abs % scale).toString().padStart(decimals, '0').slice(0, shown).padEnd(shown, '0')
    out += `.${frac}`
  }
  return negative ? `-${out}` : out
}

/** A token amount: whole tokens when the amount is whole, otherwise up to four decimals. */
export function formatTokens(value: bigint): string {
  if (value % 10n ** 18n === 0n) return formatFixed(value, 18, 0)
  if (value > 0n && value < 10n ** 14n) return '< 0.0001'
  const s = formatFixed(value, 18, 4).replace(/0+$/, '')
  return s.endsWith('.') ? `${s}0` : s
}

/** A token amount with its noun: 1 token, 2.5 tokens. */
export function formatTokenCount(value: bigint): string {
  return `${formatTokens(value)} ${value === 10n ** 18n ? 'token' : 'tokens'}`
}

/**
 * A settlement currency amount, 6 decimals. To the cent when it is a whole number of cents; otherwise every unit,
 * since the distributor rounds payouts down by a unit and a cent figure would hide that or overstate it.
 */
export function formatEurc(value: bigint): string {
  if (value % 10_000n === 0n) return formatFixed(value, 6, 2)
  return formatFixed(value, 6, 6).replace(/0+$/, '')
}

/** An amount in base units as a Solidity literal would write it: 10e18 when it is whole, every digit otherwise. */
export function solidityAmount(value: bigint, decimals: number): string {
  const scale = 10n ** BigInt(decimals)
  return value !== 0n && value % scale === 0n ? `${value / scale}e${decimals}` : value.toString()
}

export function shortAddress(address: string): string {
  return `${address.slice(0, 6)}…${address.slice(-4)}`
}

/** Parses a user-typed decimal amount into base units; null if it is not a valid number. */
export function parseAmount(input: string, decimals: number): bigint | null {
  const s = input.trim().replace(/,/g, '')
  if (!/^\d*\.?\d*$/.test(s) || s === '' || s === '.') return null
  const [int, frac = ''] = s.split('.')
  if (frac.length > decimals) return null
  return BigInt(int || '0') * 10n ** BigInt(decimals) + BigInt(frac.padEnd(decimals, '0') || '0')
}

/** Inverse of parseAmount for Max buttons: no grouping, trailing zeros trimmed. */
export function toInput(value: bigint, decimals: number): string {
  const scale = 10n ** BigInt(decimals)
  const frac = (value % scale).toString().padStart(decimals, '0').replace(/0+$/, '')
  return frac ? `${value / scale}.${frac}` : `${value / scale}`
}

/** A duration in words: 45 s, 4 min 10 s, 3 h 5 min, 12 days. */
export function formatDuration(seconds: number): string {
  const s = Math.max(0, Math.round(seconds))
  if (s < 60) return `${s} s`
  if (s < 3600) {
    const rest = s % 60
    return rest ? `${Math.floor(s / 60)} min ${rest} s` : `${s / 60} min`
  }
  if (s < 86_400) {
    const min = Math.round((s % 3600) / 60)
    return min ? `${Math.floor(s / 3600)} h ${min} min` : `${Math.floor(s / 3600)} h`
  }
  return `${Math.round(s / 86_400)} days`
}

/** A unix timestamp as a local date and time: 21 Nov 2026, 14:32. */
export function formatTimestamp(seconds: bigint): string {
  return new Date(Number(seconds) * 1000).toLocaleString('en-GB', {
    day: 'numeric',
    month: 'short',
    year: 'numeric',
    hour: '2-digit',
    minute: '2-digit',
  })
}

/** A unix timestamp as a local date: 21 Nov 2026. */
export function formatDate(seconds: bigint): string {
  return new Date(Number(seconds) * 1000).toLocaleDateString('en-GB', { day: 'numeric', month: 'short', year: 'numeric' })
}
