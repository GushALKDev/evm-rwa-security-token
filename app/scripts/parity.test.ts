// Checks the app's mirrored rules and math against the deployed contracts on a local anvil chain, to the wei.
// Run after ./scripts/local-chain.sh:  LOCAL_RPC=http://127.0.0.1:8545 npx vitest run scripts/parity.test.ts
// The suite moves the chain forward and reverts it to a snapshot at the end, so it can run again.
import { readFileSync } from 'node:fs'
import {
  BaseError,
  ContractFunctionRevertedError,
  createPublicClient,
  createWalletClient,
  encodeFunctionData,
  http,
  type Abi,
  type Address,
  type Hex,
} from 'viem'
import { foundry } from 'viem/chains'
import { afterAll, beforeAll, describe, expect, it } from 'vitest'
import {
  complianceAbi,
  countryRestrictionAbi,
  deskAbi,
  distributorAbi,
  identityRegistryAbi,
  lockupAbi,
  maxHoldersAbi,
  securityTokenAbi,
} from '../src/abi'
import { deskCallAbi, distributorCallAbi, tokenAbi } from '../src/lib/abi'
import {
  accumulated,
  correctionAfterMint,
  correctionSlot,
  correctionsAfterTransfer,
  couponAmount,
  couponPreview,
  decodeInt256,
  depositEffect,
  readAccumulatorSnapshot,
} from '../src/lib/dividends'
import { withGasMargin } from '../src/lib/gas'
import {
  evaluateGate,
  freeBalance,
  holderCountAfter,
  lockupEffect,
  moduleCheck,
  type GateState,
  type ModuleKind,
  type PartyState,
} from '../src/lib/gate'

const rpc = process.env.LOCAL_RPC
const NOTE = 10n ** 18n
const SPAIN = 724
const IRAN = 364
// anvil's default accounts 0 to 5, unlocked on a local node. Account 0 deployed and holds every role.
const deployer = '0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266' as Address
const alice = '0x70997970C51812dc3A010C7d01b50e0d17dc79C8' as Address
const bob = '0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC' as Address
const carol = '0x90F79bf6EB2c4f870365E785982E1f101E93b906' as Address
const dave = '0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65' as Address
const erin = '0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc' as Address
// Never registered and never funded: the wallet a visitor types in by hand.
const stranger = '0x000000000000000000000000000000000000dEaD' as Address

interface LocalDeployment {
  token: Address
  identityRegistry: Address
  compliance: Address
  maxHolders: Address
  countryRestriction: Address
  lockup: Address
  distributor: Address
  desk: Address
  currency: Address
  seeds: Record<string, Address>
}

describe.skipIf(!rpc)('parity with the contracts on a local chain', () => {
  // Read lazily: the local deployment file is not committed, and a skipped suite still gets collected.
  let d: LocalDeployment
  let snapshot: Hex
  const pub = createPublicClient({ chain: foundry, transport: http(rpc) })
  const wallet = createWalletClient({ chain: foundry, transport: http(rpc) })

  beforeAll(async () => {
    d = JSON.parse(readFileSync(new URL('../src/config/deployments/31337.json', import.meta.url), 'utf8'))
    snapshot = await pub.request({ method: 'evm_snapshot' as never })
    for (const seed of Object.values(d.seeds)) {
      await pub.request({ method: 'anvil_impersonateAccount' as never, params: [seed] as never })
      await pub.request({ method: 'anvil_setBalance' as never, params: [seed, '0xde0b6b3a7640000'] as never })
    }
  })

  afterAll(async () => {
    if (snapshot) await pub.request({ method: 'evm_revert' as never, params: [snapshot] as never })
  })

  /* ---------------------------------------------------------------- */
  /* Helpers                                                          */
  /* ---------------------------------------------------------------- */

  /** Sends a call from an unlocked or impersonated account, optionally with a fixed gas limit, and returns the receipt. */
  async function send(from: Address, address: Address, abi: Abi | readonly unknown[], functionName: string, args: readonly unknown[] = [], gas?: bigint) {
    const hash = await wallet.writeContract({ account: from, address, abi: abi as Abi, functionName, args, gas } as never)
    return pub.waitForTransactionReceipt({ hash })
  }

  async function sendOk(from: Address, address: Address, abi: Abi | readonly unknown[], functionName: string, args: readonly unknown[] = []) {
    const receipt = await send(from, address, abi, functionName, args)
    expect(receipt.status, `${functionName} from ${from}`).toBe('success')
    return receipt
  }

  async function mineAt(timestamp: bigint) {
    await pub.request({ method: 'evm_setNextBlockTimestamp' as never, params: [Number(timestamp)] as never })
    await pub.request({ method: 'evm_mine' as never })
  }

  const latest = () => pub.getBlock()

  async function readParty(address: Address, blockNumber: bigint): Promise<PartyState> {
    const at = { blockNumber }
    const [id, balance, frozen, frozenTokens, lockStart] = await Promise.all([
      pub.readContract({ address: d.identityRegistry, abi: identityRegistryAbi, functionName: 'identity', args: [address], ...at }),
      pub.readContract({ address: d.token, abi: securityTokenAbi, functionName: 'balanceOf', args: [address], ...at }),
      pub.readContract({ address: d.token, abi: securityTokenAbi, functionName: 'isFrozen', args: [address], ...at }),
      pub.readContract({ address: d.token, abi: securityTokenAbi, functionName: 'frozenTokens', args: [address], ...at }),
      pub.readContract({ address: d.lockup, abi: lockupAbi, functionName: 'lockStart', args: [address], ...at }),
    ])
    return {
      address,
      verified: id.verified,
      kycExpiry: BigInt(id.kycExpiry),
      country: Number(id.country),
      investorId: id.investorId,
      balance,
      frozen,
      frozenTokens,
      lockStart: BigInt(lockStart),
    }
  }

  function kindOf(module: Address): ModuleKind {
    const a = module.toLowerCase()
    if (a === d.maxHolders.toLowerCase()) return 'maxHolders'
    if (a === d.countryRestriction.toLowerCase()) return 'country'
    if (a === d.lockup.toLowerCase()) return 'lockup'
    if (a === d.distributor.toLowerCase()) return 'distributor'
    return 'unknown'
  }

  async function readGate(parties: PartyState[], blockNumber: bigint): Promise<GateState> {
    const at = { blockNumber }
    const [paused, holderCount, maxHolders, lockupPeriod, modules] = await Promise.all([
      pub.readContract({ address: d.token, abi: securityTokenAbi, functionName: 'paused', ...at }),
      pub.readContract({ address: d.maxHolders, abi: maxHoldersAbi, functionName: 'holderCount', ...at }),
      pub.readContract({ address: d.maxHolders, abi: maxHoldersAbi, functionName: 'maxHolders', ...at }),
      pub.readContract({ address: d.lockup, abi: lockupAbi, functionName: 'lockupPeriod', ...at }),
      pub.readContract({ address: d.compliance, abi: complianceAbi, functionName: 'modules', ...at }),
    ])
    const codes = [...new Set(parties.map((p) => p.country))]
    const flags = await Promise.all(
      codes.map((c) => pub.readContract({ address: d.countryRestriction, abi: countryRestrictionAbi, functionName: 'isRestricted', args: [c], ...at })),
    )
    return {
      paused,
      holderCount,
      maxHolders,
      lockupPeriod: BigInt(lockupPeriod),
      restricted: new Map(codes.map((c, i) => [c, flags[i]])),
      modules: modules.map((address) => ({ address, kind: kindOf(address) })),
    }
  }

  /** The error the call reverts with, decoded from the combined ABI, or null when it would succeed. */
  async function revertOf(from: Address, functionName: 'transfer' | 'mint', args: readonly unknown[], blockNumber: bigint) {
    try {
      await pub.simulateContract({ address: d.token, abi: tokenAbi, functionName, args, account: from, blockNumber } as never)
      return null
    } catch (err) {
      const reverted = err instanceof BaseError ? (err.walk((e) => e instanceof ContractFunctionRevertedError) as ContractFunctionRevertedError | null) : null
      if (!reverted?.data) throw err
      return { name: reverted.data.errorName, args: [...(reverted.data.args ?? [])] }
    }
  }

  const correctionOf = async (account: Address, blockNumber?: bigint) =>
    decodeInt256(await pub.getStorageAt({ address: d.distributor, slot: correctionSlot(account), blockNumber }))

  const accumulatedOf = (account: Address, blockNumber?: bigint) =>
    pub.readContract({ address: d.distributor, abi: distributorAbi, functionName: 'accumulated', args: [account], blockNumber })

  const claimableOf = (account: Address, blockNumber?: bigint) =>
    pub.readContract({ address: d.distributor, abi: distributorAbi, functionName: 'claimable', args: [account], blockNumber })

  /**
   * Runs the gate for every sender, recipient and amount in the matrix, at the latest block, against canTransfer,
   * every module's moduleCheck and the revert the token itself raises. Returns how many cases it checked.
   */
  async function checkMatrix(): Promise<{ cases: number; outcomes: Set<string> }> {
    const block = await latest()
    const n = block.number
    const addresses = [...Object.values(d.seeds), alice, bob, carol, stranger]
    const parties = await Promise.all(addresses.map((a) => readParty(a, n)))
    const gate = await readGate(parties, n)
    const outcomes = new Set<string>()
    let cases = 0
    for (const from of [null, ...parties]) {
      const amounts = from
        ? [...new Set([0n, 1n, NOTE, freeBalance(from), freeBalance(from) + 1n, from.balance])]
        : [0n, 1n, NOTE]
      for (const to of parties) {
        for (const amount of amounts) {
          const mirror = evaluateGate(gate, from, to, amount, block.timestamp)
          const label = `${from?.address ?? 'mint'} -> ${to.address}, ${amount}`
          const onChain = await pub.readContract({
            address: d.token,
            abi: securityTokenAbi,
            functionName: 'canTransfer',
            args: [from?.address ?? '0x0000000000000000000000000000000000000000', to.address, amount],
            blockNumber: n,
          })
          expect(mirror.ok, `canTransfer ${label}`).toBe(onChain)
          for (const m of gate.modules) {
            const chainCheck = await pub.readContract({
              address: m.address,
              abi: lockupAbi,
              functionName: 'moduleCheck',
              args: [from?.address ?? '0x0000000000000000000000000000000000000000', to.address, amount],
              blockNumber: n,
            })
            expect(moduleCheck(m.kind, gate, from, to, amount, block.timestamp).pass, `${m.kind} ${label}`).toBe(chainCheck)
          }
          const revert = from
            ? await revertOf(from.address, 'transfer', [to.address, amount], n)
            : await revertOf(deployer, 'mint', [to.address, amount], n)
          expect(revert, `revert ${label}`).toEqual(mirror.revert)
          outcomes.add(mirror.revert?.name ?? 'Ok')
          cases++
        }
      }
    }
    return { cases, outcomes }
  }

  /* ---------------------------------------------------------------- */
  /* The gate                                                         */
  /* ---------------------------------------------------------------- */

  it('sets up visitors the way the app does', async () => {
    // alice: verified, with notes, locked. bob: never verified. carol: verified, in a restricted country.
    await sendOk(alice, d.desk, deskCallAbi, 'onboard', [SPAIN])
    await sendOk(alice, d.desk, deskCallAbi, 'claimNotes')
    await sendOk(carol, d.desk, deskCallAbi, 'onboard', [IRAN])
    expect(await pub.readContract({ address: d.token, abi: securityTokenAbi, functionName: 'balanceOf', args: [alice] })).toBe(10n * NOTE)
  })

  it('matches canTransfer, every moduleCheck and the token revert while lockups run', async () => {
    const { cases, outcomes } = await checkMatrix()
    expect(cases).toBeGreaterThan(400)
    // The matrix reaches every revert the gate can raise apart from the pause.
    for (const name of ['Ok', 'RecipientNotVerified', 'RecipientAddressFrozen', 'SenderNotVerified', 'SenderAddressFrozen', 'InsufficientUnfrozenBalance', 'ComplianceCheckFailed'])
      expect(outcomes.has(name), name).toBe(true)
  }, 120_000)

  it('matches them again once lockups have run out and the lapsed attestation has expired', async () => {
    const block = await latest()
    await mineAt(block.timestamp + 3_600n)
    const { cases } = await checkMatrix()
    expect(cases).toBeGreaterThan(400)
  }, 120_000)

  it('matches them while the token is paused', async () => {
    await sendOk(deployer, d.token, securityTokenAbi, 'pause')
    const block = await latest()
    const parties = await Promise.all([alice, d.seeds.settled].map((a) => readParty(a, block.number)))
    const gate = await readGate(parties, block.number)
    const mirror = evaluateGate(gate, parties[0], parties[1], NOTE, block.timestamp)
    expect(mirror.revert).toEqual({ name: 'EnforcedPause', args: [] })
    expect(await revertOf(alice, 'transfer', [d.seeds.settled, NOTE], block.number)).toEqual(mirror.revert)
    expect(await pub.readContract({ address: d.token, abi: securityTokenAbi, functionName: 'canTransfer', args: [alice, d.seeds.settled, NOTE] })).toBe(false)
    await sendOk(deployer, d.token, securityTokenAbi, 'unpause')
  })

  it('evaluates the lockup at the latest block timestamp, one second either side of the unlock', async () => {
    // erin joins now, so her clock starts at a known block.
    await sendOk(erin, d.desk, deskCallAbi, 'onboard', [SPAIN])
    const receipt = await sendOk(erin, d.desk, deskCallAbi, 'claimNotes')
    const start = (await pub.getBlock({ blockNumber: receipt.blockNumber })).timestamp
    const period = BigInt(await pub.readContract({ address: d.lockup, abi: lockupAbi, functionName: 'lockupPeriod' }))

    for (const [t, open] of [
      [start + period - 1n, false],
      [start + period, true],
    ] as const) {
      await mineAt(t)
      const block = await latest()
      const parties = await Promise.all([erin, d.seeds.settled].map((a) => readParty(a, block.number)))
      const gate = await readGate(parties, block.number)
      const mirror = evaluateGate(gate, parties[0], parties[1], NOTE, block.timestamp)
      expect(mirror.ok, `at ${t}`).toBe(open)
      // A call made now runs at the latest block's timestamp, the same one the page evaluates at.
      expect(await pub.readContract({ address: d.token, abi: securityTokenAbi, functionName: 'canTransfer', args: [erin, d.seeds.settled, NOTE] })).toBe(open)
      expect(await revertOf(erin, 'transfer', [d.seeds.settled, NOTE], block.number)).toEqual(mirror.revert)
    }
  })

  it('predicts the holder count and the lockup clocks each transfer leaves', async () => {
    // bob joins so he can receive; dave stays empty until he receives.
    await sendOk(bob, d.desk, deskCallAbi, 'onboard', [SPAIN])
    await sendOk(dave, d.desk, deskCallAbi, 'onboard', [SPAIN])
    const cases: [Address, Address, bigint][] = [
      [alice, dave, NOTE], // a new holder
      [alice, d.seeds.settled, NOTE], // an existing holder
      [alice, alice, NOTE], // a self-transfer
      [dave, bob, NOTE], // dave exits to zero and bob joins: one replaces the other
    ]
    for (const [from, to, amount] of cases) {
      const before = await latest()
      const parties = await Promise.all([from, to].map((a) => readParty(a, before.number)))
      const count = await pub.readContract({ address: d.maxHolders, abi: maxHoldersAbi, functionName: 'holderCount', blockNumber: before.number })
      const predicted = holderCountAfter(count, parties[0], parties[1], amount)
      const effect = lockupEffect(parties[0], parties[1], amount)
      if (from === dave) await mineAt(before.timestamp + 3_600n)
      const receipt = await sendOk(from, d.token, tokenAbi, 'transfer', [to, amount])
      const after = await Promise.all([from, to].map((a) => readParty(a, receipt.blockNumber)))
      expect(await pub.readContract({ address: d.maxHolders, abi: maxHoldersAbi, functionName: 'holderCount' }), `count ${from} -> ${to}`).toBe(predicted)
      const landed = (await pub.getBlock({ blockNumber: receipt.blockNumber })).timestamp
      if (effect.recipientStarts) expect(after[1].lockStart).toBe(landed)
      else expect(after[1].lockStart).toBe(parties[1].lockStart)
      if (effect.senderCleared) expect(after[0].lockStart).toBe(0n)
    }
  })

  /* ---------------------------------------------------------------- */
  /* Dividends                                                        */
  /* ---------------------------------------------------------------- */

  it('predicts a coupon to the wei: amount, accumulator, remainder and every holder share', async () => {
    const next = await pub.readContract({ address: d.desk, abi: deskAbi, functionName: 'nextCouponAt' })
    const block = await latest()
    if (block.timestamp < next) await mineAt(next)
    const pre = await latest()
    const n = pre.number
    const [supply, dps, residue, perNote, quoted] = await Promise.all([
      pub.readContract({ address: d.token, abi: securityTokenAbi, functionName: 'totalSupply', blockNumber: n }),
      pub.readContract({ address: d.distributor, abi: distributorAbi, functionName: 'dividendsPerShare', blockNumber: n }),
      pub.readContract({ address: d.distributor, abi: distributorAbi, functionName: 'residue', blockNumber: n }),
      pub.readContract({ address: d.desk, abi: deskAbi, functionName: 'COUPON_PER_NOTE', blockNumber: n }),
      pub.readContract({ address: d.desk, abi: deskAbi, functionName: 'couponAmount', blockNumber: n }),
    ])
    const amount = couponAmount(supply, perNote)
    expect(amount).toBe(quoted)
    const after = depositEffect(dps, residue, supply, amount)

    const holders = [alice, bob, d.seeds.settled, d.seeds.partlyFrozen, d.seeds.lapsed]
    const previews = await Promise.all(
      holders.map(async (h) => {
        const [p, corr] = await Promise.all([readParty(h, n), correctionOf(h, n)])
        expect(accumulated(p.balance, dps, corr), `accumulated before, ${h}`).toBe(await accumulatedOf(h, n))
        return accumulated(p.balance, after.dividendsPerShare, corr) - accumulated(p.balance, dps, corr)
      }),
    )
    const claimableBefore = await Promise.all(holders.map((h) => claimableOf(h, n)))

    await sendOk(carol, d.desk, deskCallAbi, 'payCoupon')

    expect(await pub.readContract({ address: d.distributor, abi: distributorAbi, functionName: 'dividendsPerShare' })).toBe(after.dividendsPerShare)
    expect(await pub.readContract({ address: d.distributor, abi: distributorAbi, functionName: 'residue' })).toBe(after.residue)
    for (const [i, h] of holders.entries()) {
      expect((await claimableOf(h)) - claimableBefore[i], `share of ${h}`).toBe(previews[i])
    }
  })

  it('tracks the corrections a transfer and a mint write, and leaves both sides income untouched', async () => {
    const pre = await latest()
    const [a, s] = await Promise.all([readParty(alice, pre.number), readParty(d.seeds.settled, pre.number)])
    const dps = await pub.readContract({ address: d.distributor, abi: distributorAbi, functionName: 'dividendsPerShare' })
    const [ca, cs] = await Promise.all([correctionOf(alice), correctionOf(d.seeds.settled)])
    const [owedA, owedS] = await Promise.all([claimableOf(alice), claimableOf(d.seeds.settled)])

    await sendOk(alice, d.token, tokenAbi, 'transfer', [d.seeds.settled, 2n * NOTE])
    const moved = correctionsAfterTransfer(ca, cs, 2n * NOTE, dps, false)
    expect(await correctionOf(alice)).toBe(moved.from)
    expect(await correctionOf(d.seeds.settled)).toBe(moved.to)
    expect(accumulated(a.balance - 2n * NOTE, dps, moved.from)).toBe(await accumulatedOf(alice))
    expect(accumulated(s.balance + 2n * NOTE, dps, moved.to)).toBe(await accumulatedOf(d.seeds.settled))
    expect(await claimableOf(alice)).toBe(owedA)
    expect(await claimableOf(d.seeds.settled)).toBe(owedS)

    // A mint after income was paid earns nothing from it.
    const fresh = '0xa0Ee7A142d267C1f36714E4a8F75612F20a79720' as Address
    await sendOk(fresh, d.desk, deskCallAbi, 'onboard', [SPAIN])
    const c0 = await correctionOf(fresh)
    await sendOk(fresh, d.desk, deskCallAbi, 'claimNotes')
    expect(await correctionOf(fresh)).toBe(correctionAfterMint(c0, 10n * NOTE, dps))
    expect(await claimableOf(fresh)).toBe(0n)

    // The dividends page reads these inputs as one snapshot, at one block: it agrees with the contract there.
    for (const who of [fresh, alice, d.seeds.settled]) {
      const snap = await readAccumulatorSnapshot(pub as never, d, who)
      expect(accumulated(snap.balance, snap.dividendsPerShare, snap.correction), `snapshot of ${who}`).toBe(
        await accumulatedOf(who, snap.blockNumber),
      )
      expect(couponPreview(snap, 5_000_000n)).not.toBeNull()
    }
  })

  it('pays exactly the claimable amount and leaves nothing to claim', async () => {
    const owed = await claimableOf(alice)
    expect(owed).toBeGreaterThan(0n)
    const balance = (a: Address) => pub.readContract({ address: d.currency, abi: tokenAbi, functionName: 'balanceOf', args: [a] })
    const before = await balance(alice)
    await sendOk(alice, d.distributor, distributorCallAbi, 'claim', [alice])
    expect((await balance(alice)) - before).toBe(owed)
    expect(await claimableOf(alice)).toBe(0n)
  })

  /* ---------------------------------------------------------------- */
  /* Gas                                                              */
  /* ---------------------------------------------------------------- */

  it('covers a recipient that empties its wallet between the estimate and the block', async () => {
    // Estimated while dave holds notes; by the time the transfer lands he holds none, so it writes his balance,
    // lockup clock and correction from zero and moves the holder count.
    await sendOk(alice, d.token, tokenAbi, 'transfer', [dave, NOTE])
    const block = await latest()
    await mineAt(block.timestamp + 3_600n)
    const data = encodeFunctionData({ abi: tokenAbi, functionName: 'transfer', args: [dave, NOTE] })
    const estimate = await pub.estimateGas({ account: alice, to: d.token, data })
    const daveNotes = await pub.readContract({ address: d.token, abi: securityTokenAbi, functionName: 'balanceOf', args: [dave] })
    await sendOk(dave, d.token, tokenAbi, 'transfer', [bob, daveNotes])

    // The lending demo app's margin (25% plus 25,000) runs out of gas here; this app's margin does not.
    const snap = await pub.request({ method: 'evm_snapshot' as never })
    const short = await send(alice, d.token, tokenAbi, 'transfer', [dave, NOTE], (estimate * 125n) / 100n + 25_000n)
    expect(short.status).toBe('reverted')
    await pub.request({ method: 'evm_revert' as never, params: [snap] as never })
    const enough = await send(alice, d.token, tokenAbi, 'transfer', [dave, NOTE], withGasMargin(estimate))
    expect(enough.status).toBe('success')
    expect(enough.gasUsed).toBeGreaterThan(estimate)
  })
})
