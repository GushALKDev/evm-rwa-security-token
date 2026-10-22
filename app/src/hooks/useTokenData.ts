import { useQuery } from '@tanstack/react-query'
import { useMemo } from 'react'
import { parseAbi, type Abi, type Address, type Hex } from 'viem'
import { useBalance, usePublicClient, useReadContracts } from 'wagmi'
import { deployment } from '../config/chain'
import type { Deployment } from '../config/deployment'
import {
  complianceAbi,
  countryRestrictionAbi,
  currencyAbi,
  deskAbi,
  distributorAbi,
  documentRegistryAbi,
  identityRegistryAbi,
  lockupAbi,
  maxHoldersAbi,
  securityTokenAbi,
} from '../lib/abi'
import { countries } from '../lib/countries'
import { correctionSlot, decodeInt256 } from '../lib/dividends'
import type { PartyState } from '../lib/gate'

export interface StaticData {
  tokenName: string
  tokenSymbol: string
  kycValidity: bigint
  notesPerClaim: bigint
  claimCooldown: bigint
  couponInterval: bigint
  couponPerNote: bigint
  currencySymbol: string
  terms: { uri: string; contentHash: Hex; lastModified: bigint }
  domainSeparator: Hex
  attestationTypehash: Hex
  claimSigner: Address
  moduleNames: Record<string, string>
}

export interface LiveData {
  totalSupply: bigint
  paused: boolean
  holderCount: bigint
  maxHolders: bigint
  lockupPeriod: bigint
  modules: Address[]
  dividendsPerShare: bigint
  residue: bigint
  /** EURC the distributor holds: deposited and not yet claimed */
  distributorHeld: bigint
  lastCouponAt: bigint
  nextCouponAt: bigint
  couponAmount: bigint
}

export interface PartyData extends PartyState {
  accredited: boolean
  claimable: bigint
  withdrawn: bigint
}

export interface AccountExtras {
  /** Unknown while loading, so the interface does not flash a no-gas warning */
  eth: bigint | undefined
  eurc: bigint
  nextClaimAt: bigint
}

const REFRESH_MS = 6_000

// Every compliance module exposes name(); one fragment reads it from any of them.
const moduleNameAbi = parseAbi(['function name() view returns (string)'])

interface Read {
  address: Address
  abi: Abi
  functionName: string
  args?: readonly unknown[]
}

const asReads = (reads: unknown[]) => reads as Read[]

function useReads(contracts: Read[], query: { enabled?: boolean; staleTime?: number; refetchInterval?: number }) {
  const res = useReadContracts({ allowFailure: false, contracts: contracts as never, query })
  return { ...res, data: res.data as unknown as readonly unknown[] | undefined }
}

function useStatic(d: Deployment) {
  const moduleAddresses = [d.maxHolders, d.countryRestriction, d.lockup, d.distributor]
  const res = useReads(
    asReads([
      { address: d.token, abi: securityTokenAbi, functionName: 'name' },
      { address: d.token, abi: securityTokenAbi, functionName: 'symbol' },
      { address: d.desk, abi: deskAbi, functionName: 'KYC_VALIDITY' },
      { address: d.desk, abi: deskAbi, functionName: 'NOTES_PER_CLAIM' },
      { address: d.desk, abi: deskAbi, functionName: 'CLAIM_COOLDOWN' },
      { address: d.desk, abi: deskAbi, functionName: 'COUPON_INTERVAL' },
      { address: d.desk, abi: deskAbi, functionName: 'COUPON_PER_NOTE' },
      { address: d.currency, abi: currencyAbi, functionName: 'symbol' },
      { address: d.documentRegistry, abi: documentRegistryAbi, functionName: 'getDocument', args: [d.termsName] },
      { address: d.identityRegistry, abi: identityRegistryAbi, functionName: 'domainSeparator' },
      { address: d.identityRegistry, abi: identityRegistryAbi, functionName: 'ATTESTATION_TYPEHASH' },
      { address: d.identityRegistry, abi: identityRegistryAbi, functionName: 'claimSigner' },
      ...moduleAddresses.map((address) => ({ address, abi: moduleNameAbi, functionName: 'name' })),
    ]),
    { staleTime: Infinity },
  )
  const data = useMemo((): StaticData | undefined => {
    const r = res.data
    if (!r) return undefined
    const [uri, contentHash, lastModified] = r[8] as readonly [string, Hex, bigint]
    return {
      tokenName: r[0] as string,
      tokenSymbol: r[1] as string,
      kycValidity: BigInt(r[2] as bigint),
      notesPerClaim: r[3] as bigint,
      claimCooldown: r[4] as bigint,
      couponInterval: r[5] as bigint,
      couponPerNote: r[6] as bigint,
      currencySymbol: r[7] as string,
      terms: { uri, contentHash, lastModified: BigInt(lastModified) },
      domainSeparator: r[9] as Hex,
      attestationTypehash: r[10] as Hex,
      claimSigner: r[11] as Address,
      moduleNames: Object.fromEntries(moduleAddresses.map((a, i) => [a.toLowerCase(), r[12 + i] as string])),
    }
  }, [res.data])
  return { ...res, data }
}

function useLive(d: Deployment) {
  const res = useReads(
    asReads([
      { address: d.token, abi: securityTokenAbi, functionName: 'totalSupply' },
      { address: d.token, abi: securityTokenAbi, functionName: 'paused' },
      { address: d.maxHolders, abi: maxHoldersAbi, functionName: 'holderCount' },
      { address: d.maxHolders, abi: maxHoldersAbi, functionName: 'maxHolders' },
      { address: d.lockup, abi: lockupAbi, functionName: 'lockupPeriod' },
      { address: d.compliance, abi: complianceAbi, functionName: 'modules' },
      { address: d.distributor, abi: distributorAbi, functionName: 'dividendsPerShare' },
      { address: d.distributor, abi: distributorAbi, functionName: 'residue' },
      { address: d.currency, abi: currencyAbi, functionName: 'balanceOf', args: [d.distributor] },
      { address: d.desk, abi: deskAbi, functionName: 'lastCouponAt' },
      { address: d.desk, abi: deskAbi, functionName: 'nextCouponAt' },
      { address: d.desk, abi: deskAbi, functionName: 'couponAmount' },
    ]),
    { refetchInterval: REFRESH_MS },
  )
  const data = useMemo((): LiveData | undefined => {
    const r = res.data
    if (!r) return undefined
    return {
      totalSupply: r[0] as bigint,
      paused: r[1] as boolean,
      holderCount: r[2] as bigint,
      maxHolders: r[3] as bigint,
      lockupPeriod: BigInt(r[4] as bigint),
      modules: r[5] as Address[],
      dividendsPerShare: r[6] as bigint,
      residue: r[7] as bigint,
      distributorHeld: r[8] as bigint,
      lastCouponAt: r[9] as bigint,
      nextCouponAt: r[10] as bigint,
      couponAmount: r[11] as bigint,
    }
  }, [res.data])
  return { ...res, data }
}

const PARTY_READS = 7

/** Everything the gate and the position card read about a set of wallets. */
export function useParties(addresses: Address[]) {
  const d = deployment as Deployment
  const res = useReads(
    asReads(
      addresses.flatMap((a) => [
        { address: d.identityRegistry, abi: identityRegistryAbi, functionName: 'identity', args: [a] },
        { address: d.token, abi: securityTokenAbi, functionName: 'balanceOf', args: [a] },
        { address: d.token, abi: securityTokenAbi, functionName: 'isFrozen', args: [a] },
        { address: d.token, abi: securityTokenAbi, functionName: 'frozenTokens', args: [a] },
        { address: d.lockup, abi: lockupAbi, functionName: 'lockStart', args: [a] },
        { address: d.distributor, abi: distributorAbi, functionName: 'claimable', args: [a] },
        { address: d.distributor, abi: distributorAbi, functionName: 'withdrawn', args: [a] },
      ]),
    ),
    { enabled: addresses.length > 0, refetchInterval: REFRESH_MS },
  )
  const data = useMemo((): PartyData[] | undefined => {
    const r = res.data
    if (!r) return undefined
    return addresses.map((address, i) => {
      const at = (k: number) => r[i * PARTY_READS + k]
      const id = at(0) as { verified: boolean; accredited: boolean; country: number; kycExpiry: bigint; investorId: Hex }
      return {
        address,
        verified: id.verified,
        accredited: id.accredited,
        country: Number(id.country),
        kycExpiry: BigInt(id.kycExpiry),
        investorId: id.investorId,
        balance: at(1) as bigint,
        frozen: at(2) as boolean,
        frozenTokens: at(3) as bigint,
        lockStart: BigInt(at(4) as bigint),
        claimable: at(5) as bigint,
        withdrawn: at(6) as bigint,
      }
    })
  }, [res.data, addresses])
  return { data, isLoading: res.isLoading, error: res.error }
}

/**
 * Restriction flags for the countries the desk offers, the deployment restricted, and any other country a wallet
 * on the page carries. The module stores a blocklist it cannot enumerate, so each code is read on its own.
 */
export function useRestricted(extraCodes: number[]) {
  const d = deployment as Deployment
  const codes = useMemo(() => {
    const set = new Set<number>([...countries.map((c) => c.code), ...d.restrictedCountries, ...extraCodes])
    set.delete(0)
    return [...set].sort((a, b) => a - b)
  }, [d.restrictedCountries, extraCodes])
  const res = useReads(
    asReads(codes.map((c) => ({ address: d.countryRestriction, abi: countryRestrictionAbi, functionName: 'isRestricted', args: [c] }))),
    { refetchInterval: REFRESH_MS },
  )
  const data = useMemo(() => {
    const r = res.data
    if (!r) return undefined
    return new Map<number, boolean>(codes.map((c, i) => [c, r[i] as boolean]))
  }, [res.data, codes])
  return { data, error: res.error }
}

function useAccountExtras(d: Deployment, account: Address | undefined) {
  const user = account ?? '0x0000000000000000000000000000000000000000'
  const eth = useBalance({ address: account, query: { enabled: !!account, refetchInterval: REFRESH_MS } })
  const reads = useReads(
    asReads([
      { address: d.currency, abi: currencyAbi, functionName: 'balanceOf', args: [user] },
      { address: d.desk, abi: deskAbi, functionName: 'nextClaimAt', args: [user] },
    ]),
    { enabled: !!account, refetchInterval: REFRESH_MS },
  )
  const data = useMemo((): AccountExtras | undefined => {
    const r = reads.data
    if (!r || !account) return undefined
    return { eth: eth.data?.value, eurc: r[0] as bigint, nextClaimAt: r[1] as bigint }
  }, [reads.data, account, eth.data?.value])
  return { data, error: reads.error }
}

/**
 * The distributor's correction for one account, read from storage: it has no getter, and the exact share of the
 * next coupon depends on its remainder modulo the accumulator's scale.
 */
export function useCorrection(account: Address | undefined, refreshKey: unknown) {
  const d = deployment as Deployment
  const client = usePublicClient()
  return useQuery({
    queryKey: ['correction', d.distributor, account, refreshKey],
    enabled: !!account && !!client,
    refetchInterval: REFRESH_MS,
    queryFn: async () => decodeInt256(await client!.getStorageAt({ address: d.distributor, slot: correctionSlot(account!) })),
  })
}

export function useTokenData(account: Address | undefined) {
  const d = deployment as Deployment
  const st = useStatic(d)
  const live = useLive(d)
  const addresses = useMemo(() => {
    const list: Address[] = d.seeds.map((s) => s.address)
    if (account && !list.some((a) => a.toLowerCase() === account.toLowerCase())) list.unshift(account)
    return list
  }, [d.seeds, account])
  const parties = useParties(addresses)
  const extraCodes = useMemo(() => (parties.data ?? []).map((p) => p.country), [parties.data])
  const restricted = useRestricted(extraCodes)
  const extras = useAccountExtras(d, account)
  return {
    deployment: d,
    static: st.data,
    live: live.data,
    parties: parties.data,
    restricted: restricted.data,
    extras: extras.data,
    error: st.error ?? live.error ?? parties.error ?? restricted.error ?? extras.error,
    isLoading: st.isLoading || live.isLoading || parties.isLoading,
  }
}
