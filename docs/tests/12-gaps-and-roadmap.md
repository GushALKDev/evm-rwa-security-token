# Gaps & Roadmap

**Section:** [Testing Documentation](./README.md)

---

> What the suite does not cover, stated plainly so the gaps are not mistaken for oversights. Each entry says whether it is **open** (it could be closed and is not yet scheduled), an **accepted limitation** (it will not be closed, and why), or **closed** (kept here as a record of what changed).

## Open

### Deployment handover

`_deploy` requires the executing account to be the issuer, since the wiring calls are admin-gated. Passing a different issuer grants that address admin and then reverts on the first wiring call. A real deployment wants deploy-then-handover: the deployer wires everything, then transfers `DEFAULT_ADMIN_ROLE` to the real issuer. The script's NatSpec documents this and [Guide 7](../07-security.md#trust-assumptions-and-limitations) lists it under trust assumptions; it is untested because the handover step does not exist yet.

### Module addition and removal are not in the invariant handler

The invariant suite attaches all four modules in `setUp`, and the handler never adds or removes one during a run. The attachment rules (a stateful module refuses a token with supply and a second attach, a detached distributor refuses deposits, a module must read the engine's token) are covered by point tests in [Modular Compliance](./03-modular-compliance.md#attachment-the-plug-and-play-shape), the module suites and [Regressions, finding 6](./14-regressions.md#6-stateful-modules-could-be-attached-where-they-could-not-keep-up), but not interleaved with transfers, recoveries and deposits in arbitrary order. Closing it means `addModule` and `removeModule` actions for the plug-and-play country module (the one that may come back) and a one-way removal for the others, with the invariants that read a removed module's state made conditional on it being attached.

### The deeper runs are documented, not automated

CI runs the `ci` profile (1,000 fuzz runs, 256 invariant runs of depth 128). The two deeper configurations, `FOUNDRY_INVARIANT_RUNS=300 FOUNDRY_INVARIANT_DEPTH=100` for the invariant suite and `FOUNDRY_FUZZ_RUNS=20000` for `DividendDistributorTest`, are run by hand before trusting a change to a stateful module or to the dividend arithmetic. Nothing enforces that they were run.

### No EIP-1271 contract signers

The attestation path recovers an ECDSA address and compares it with the claim signer, so a contract (a multisig, a smart account) cannot be the claim signer. [`test_contractSigner_isNotSupported`](../../test/conformance/EIP712Conformance.t.sol#L121) pins this: with a contract that would approve any signature set as signer, every signature is refused. Closing it means an `isValidSignature` call on the signed path when the claim signer is a contract.

### The holder cap counts wallets, not investors

`MaxHoldersModule` counts addresses with a balance. One investor with two wallets counts twice, and the invariant [`invariant_holderCountMatchesReality`](../../test/invariant/Invariants.t.sol#L166) asserts exactly that per-wallet count (its six actors are three investors). A regulation that counts holders of record or beneficial owners would need the count keyed by `investorId`, which the registry already carries. No test asserts an investor-level count, because the module does not implement one. Closing it means keying the count by `investorId` and moving the per-wallet invariant to per-investor.

---

## Accepted limitations

### The `transferFrom` spender is not checked

The gate checks sender and recipient only; an unverified or frozen spender can move tokens between two verified, unfrozen holders within an allowance. ERC-3643 behaves the same way. [`test_transferFrom_spenderIsNotChecked`](../../test/unit/SecurityToken.t.sol#L638) pins it, and the invariant handler's outsider exercises it throughout a run.

### Coverage is not complete on every metric

`forge coverage --report summary` reports, for lines, statements, branches and functions:

- `SecurityToken`, `IdentityRegistry`, `ModularCompliance`, `DocumentRegistry` and `AbstractComplianceModule` at full coverage on all four.
- `CountryRestrictionModule` 24/25 lines (96.00%) and 21/22 statements (95.45%), `DividendDistributor` 59/60 (98.33%) and 68/69 (98.55%), `LockupModule` 63/64 (98.44%) and 77/78 (98.72%), `MaxHoldersModule` 46/47 (97.87%) and 71/72 (98.61%), each with every branch and function covered. In each of the four modules the one unmarked line is the constant return of a `pure` view (`isPlugAndPlay` or `token`) that the unit tests call and assert.
- `script/Deploy.s.sol` at 61/61 lines, 62/62 statements and 6/6 functions, and 15/29 branches (51.72%): the 14 untaken branches are the failure sides of the `require` checks in `_verify`, which only a mis-wired deployment could take.

Driving those branches would mean building a deployment broken in exactly each step, which asserts nothing about the real one.

### The dividend distributor is not in `Deploy.s.sol`

Phase 8 is a stretch unit, and wiring it into the deployment script would change the documented deployment and the address book the [Deployment tests](./09-deploy.md) assert against. The scenario, regression and edge-case suites register it with `addModule` after `_deploy` returns, which exercises the same wiring and additionally shows that the capability can be added to an already-live system. The invariant suite, wired by hand, attaches it before the first mint. A deployment that intends to pay income would add it to the script and to `DeployTest`.

### No upgrade, proxy or factory tests

The system deliberately has none. Contracts are immutable and deployed once; the rule set changes by adding and removing modules, not by upgrading code. The reasoning is in [Guide 4](../04-tradeoffs.md), and the migration path a later build would take is in [Guide 6](../06-improvements.md).

### No multi-token or shared-identity tests

One registry serves one token here. ERC-3643's ONCHAINID makes an identity reusable across tokens; this project collapses that into a flat registry with an `investorId`, so cross-token identity reuse is out of scope by construction.

### The off-chain half is untestable on-chain

Whether a KYC attestation reflects reality is not something the chain can verify. `isVerified` means "someone attested this and it has not expired", never "this investor is genuinely KYC-clean". `kycExpiry` is what keeps the projection honest over time, and the tests assert the expiry mechanics rather than the underlying fact. See [Guide 4 §4.3](../04-tradeoffs.md#43-on-chain-verification-is-a-projection).

### Gas is not asserted

No test pins a gas figure: a test asserting a gas number would churn with every compiler release. Gas is measured separately, by the benchmarks described in the [strategy](./01-strategy.md#1-layers), which are not part of the suite. The one storage-access property that matters on the hot path is asserted structurally instead: [`test_isVerified_readsOneStorageSlot`](../../test/unit/IdentityRegistry.t.sol#L423).

---

## Closed

### The handler-based invariant suite (roadmap 6.2 / 6.3)

Delivered as a bounded handler across arbitrary sequences, see [Invariant Suite](./11-invariants.md). It closed the gap by finding a real bug rather than merely confirming the existing tests: a self-transfer of a full balance inflated `holderCount`, which would have let anyone exhaust the holder cap.

### Invariant failures could be invisible

The first handler caught every revert with an empty `catch`, and two of its invariants could not fail. The review rebuilt it: every revert is classified as expected or unexpected per action and selector, [`invariant_noUnexpectedReverts`](../../test/invariant/Invariants.t.sol#L272) asserts the unexpected count stays zero, and the two vacuous invariants were removed or replaced. Details in [what the review changed](./11-invariants.md#what-the-review-changed).

### The dividend distributor was outside the handler suite

The distributor is now attached in the invariant suite, with `deposit` and `claim` actions (claims by frozen and unverified actors included) interleaved with pause, freeze, identity withdrawal and forced recovery. Its properties hold as [`invariant_dividendsSolvent`](../../test/invariant/Invariants.t.sol#L239), [`invariant_dividendsConserved`](../../test/invariant/Invariants.t.sol#L250) and [`invariant_blockedHoldersAreNeverPaid`](../../test/invariant/Invariants.t.sol#L259).

### `Deploy.run()` was uncovered

The script was at about 61% because the tests called only `_deploy`. [`test_run_defaultsEveryRoleToTheBroadcaster`](../../test/unit/Deploy.t.sol#L211) and [`test_run_readsOperatorsFromTheEnvironment`](../../test/unit/Deploy.t.sol#L229) now go through `run()` with the environment controlled, and lines, statements and functions are fully covered. What remains is the branch figure above.

### No standards conformance tests

The contracts were tested against their own interfaces only. The [conformance suites](./16-conformance.md) now test the token against ERC-20 and ERC-3643, the document registry against ERC-1643, and the attestation path against EIP-712, asserting each documented difference as it is.

### Edge cases and griefing vectors

Interactions between mechanisms (an identity expiring during a lockup, a pause against every role's action, a settlement currency that returns `false`) had no tests. They are in [Edge Cases](./15-edge-cases.md).

---

## Residual risks the tests deliberately do not defend against

These are **accepted design positions**, not gaps. They are listed here because a reader scanning for coverage should not mistake a deliberate decision for a missing test.

| Risk | Position |
| :--- | :------- |
| **Issuer authority is centralised** | The issuer holds `DEFAULT_ADMIN_ROLE` and can self-grant `AGENT` and `CUSTODIAN`. Faithful to ERC-3643 and to the regulatory reality it encodes. The mitigation path (multisig and timelock) is governance infrastructure, orthogonal to the architecture |
| **A custodian key plus an agent key can collude** | An agent can link an attacker-controlled wallet to a victim's `investorId`; a custodian can then recover into it. Neither key alone suffices. Contained by role separation and by the audit trail, not prevented |
| **Recovery bypasses the rule set** | Deliberate, and tested as such ([`test_forcedRecovery_succeedsWhenComplianceRejects`](../../test/unit/SecurityToken.t.sol#L751), [`test_recovery_intoBlockedJurisdictionWalletOfSameInvestor`](../../test/scenario/EdgeCases.t.sol#L168)). The consequence is that modules offer no secondary containment against a compromised custodian key: the `investorId` check and the event trail are the containment |
| **A withdrawn identity leaves a suspended balance** | An unverified address can still *hold*, just not move. This is why the coverage map phrases the property as "no unverified address can increase its balance". Confiscation is the issuer's burn or the custodian's recovery, both deliberate acts |
| **Modules are trusted code** | A registered module can revert every transfer or consume gas in the hook fan-out, which the engine bounds at 25 modules ([`test_addModule_capsTheModuleCount`](../../test/unit/ModularCompliance.t.sol#L195)). Vetting what gets registered is governance |

Full treatment of each in [Guide 4: Trade-offs](../04-tradeoffs.md) and the [threat model](../07-security.md#threat-model).

---

## Summary

| Item | Kind | Notes |
| :--- | :--- | :---- |
| Deployment handover | Open | The step does not exist yet |
| Module add/remove in the invariant handler | Open | Covered by point tests only |
| Deeper fuzz and invariant runs in CI | Open | Documented, run by hand |
| No EIP-1271 | Open | Pinned as unsupported by a conformance test |
| Holder cap counts wallets | Open | Per-wallet count asserted, investor-level count not implemented |
| `transferFrom` spender not checked | Accepted | Pinned by a unit test |
| Coverage incomplete on some metrics | Accepted | One `pure` return line per module; `_verify` failure branches |
| Distributor in `Deploy.s.sol` | Accepted | Only if the note pays income |
| Upgrades, proxies, factory | Accepted | Never (see Guide 6) |
| Multi-token identity | Accepted | Never (scope) |
| Off-chain KYC truth | Accepted | Not on-chain |
| Gas assertions | Accepted | Tests do not assert gas |
| Handler-based invariant suite | Closed | Phase 6.2 / 6.3, found a live bug |
| Invisible invariant failures | Closed | Review: revert classification |
| Distributor in the handler suite | Closed | Review: three dividend invariants |
| `Deploy.run()` coverage | Closed | Review: two `run()` tests |
| Standards conformance | Closed | Review: four suites |
| Edge cases and griefing | Closed | Review: one suite |
