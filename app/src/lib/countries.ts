// ISO 3166-1 numeric codes the onboarding desk offers. The country module stores a blocklist with no
// enumeration, so the page reads isRestricted for each of these (and for any other code a wallet carries).
export interface Country {
  code: number
  name: string
}

export const countries: Country[] = [
  { code: 724, name: 'Spain' },
  { code: 620, name: 'Portugal' },
  { code: 250, name: 'France' },
  { code: 276, name: 'Germany' },
  { code: 380, name: 'Italy' },
  { code: 528, name: 'Netherlands' },
  { code: 372, name: 'Ireland' },
  { code: 756, name: 'Switzerland' },
  { code: 826, name: 'United Kingdom' },
  { code: 840, name: 'United States' },
  { code: 364, name: 'Iran' },
  { code: 408, name: 'North Korea' },
]

export function countryName(code: number): string {
  if (code === 0) return 'no country'
  return countries.find((c) => c.code === code)?.name ?? `country ${code}`
}

/** Name with the numeric code, as the registry stores it: Spain (724). */
export function countryLabel(code: number): string {
  const c = countries.find((x) => x.code === code)
  return c ? `${c.name} (${code})` : `country ${code}`
}
