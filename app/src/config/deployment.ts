import type { Address, Hex } from 'viem'

// Deployment files are written by script/testnet/DeployTestnet.s.sol, one per chain id.
export type SeedKey = 'settled' | 'partlyFrozen' | 'frozen' | 'suspended' | 'restricted' | 'unverified' | 'lapsed'

interface RawDeployment {
  chainId: number
  deployBlock: number
  token: Address
  identityRegistry: Address
  compliance: Address
  maxHolders: Address
  countryRestriction: Address
  lockup: Address
  documentRegistry: Address
  distributor: Address
  desk: Address
  currency: Address
  termsName: Hex
  restrictedCountries: number[]
  seeds: Record<SeedKey, Address>
}

export interface Seed {
  key: SeedKey
  address: Address
  /** Short name for chips and lists */
  label: string
  /** What the deployment seeded it with, and so which outcome of the gate it shows */
  seeded: string
}

export interface Deployment {
  chainId: number
  deployBlock: bigint
  token: Address
  identityRegistry: Address
  compliance: Address
  maxHolders: Address
  countryRestriction: Address
  lockup: Address
  documentRegistry: Address
  distributor: Address
  desk: Address
  currency: Address
  termsName: Hex
  /** The jurisdictions the deployment restricted. The module has no enumeration, so this is the seeded list. */
  restrictedCountries: number[]
  seeds: Seed[]
}

// Order of the chips in the gate: the passing case first, then roughly the order of the checks they fail.
// Amounts are left out on purpose: the gate shows each wallet's live state.
const seedInfo: { key: SeedKey; label: string; seeded: string }[] = [
  { key: 'settled', label: 'Settled holder', seeded: 'Verified in Spain and holds tokens. Nothing stops it once its lockup ends.' },
  { key: 'unverified', label: 'Unverified wallet', seeded: 'Never registered in the identity registry.' },
  { key: 'lapsed', label: 'Lapsed KYC', seeded: 'Holds tokens; its attestation was written to lapse an hour after deployment.' },
  { key: 'frozen', label: 'Frozen holder', seeded: 'Holds tokens; the agent froze the whole wallet.' },
  { key: 'suspended', label: 'Suspended holder', seeded: 'Holds tokens; the agent removed its identity and the balance stayed.' },
  { key: 'partlyFrozen', label: 'Partly frozen holder', seeded: 'Holds tokens; the agent froze part of them.' },
  { key: 'restricted', label: 'Investor in Iran', seeded: 'Verified, and resident in a jurisdiction the deployment restricts.' },
]

const files = import.meta.glob<RawDeployment>('./deployments/*.json', { eager: true, import: 'default' })

export function loadDeployment(chainId: number): Deployment | null {
  const raw = files[`./deployments/${chainId}.json`]
  if (!raw) return null
  return {
    chainId: raw.chainId,
    deployBlock: BigInt(raw.deployBlock),
    token: raw.token,
    identityRegistry: raw.identityRegistry,
    compliance: raw.compliance,
    maxHolders: raw.maxHolders,
    countryRestriction: raw.countryRestriction,
    lockup: raw.lockup,
    documentRegistry: raw.documentRegistry,
    distributor: raw.distributor,
    desk: raw.desk,
    currency: raw.currency,
    termsName: raw.termsName,
    restrictedCountries: raw.restrictedCountries.map(Number),
    seeds: seedInfo.map((s) => ({ ...s, address: raw.seeds[s.key] })),
  }
}
