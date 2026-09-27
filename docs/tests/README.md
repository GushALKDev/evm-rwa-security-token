# Testing Documentation

**Version:** 2.0
**Prerequisites:** [Guide 3: Architecture](../03-architecture.md)
**Status:** Rewritten after the third review round to match the final suite

---

> This section is the executable counterpart of [Guide 5, Section 7](../05-implementation.md#7-invariants). Guide 5 states the invariants; this documents which test asserts each one, why the assertion is shaped the way it is, and links every test to the line that declares it.

---

## Contents

| Document | Covers |
| :------- | :----- |
| **[Strategy](./01-strategy.md)** | Test layers, principles (revert assertions, rounding bounds, mutation checks), infrastructure and mocks, profiles, how to run the suite, what the review changed in the tests |
| **[Identity Registry](./02-identity-registry.md)** | Phase 1: the two registration doors, replay closed on three axes, nonces on every write, investor identity, expiry, claim-signer rotation |
| **[Modular Compliance](./03-modular-compliance.md)** | Phase 2: module admin and the 25-module cap, the plug-and-play attachment rules, token matching, the AND across modules, hook fan-out and gating |
| **[Lockup Module](./04-lockup-module.md)** | Phase 2: the clock state machine, the boundary to the second, the one-wei griefing guard, the clock through a recovery |
| **[Max Holders Module](./05-max-holders-module.md)** | Phase 2: incremental counting without enumeration, replacement at cap, zero amounts, the cap-lowering guard |
| **[Country Restriction](./06-country-restriction.md)** | Phase 2: recipient-side jurisdiction blocking, and why a restricted sender may still exit |
| **[Security Token](./07-security-token.md)** | Phase 4: the transfer gate, `transferFrom`, freeze and burn arithmetic, pause, and forced recovery |
| **[Document Registry](./08-document-registry.md)** | Phase 3: content-hash anchoring, amendment as upsert, the readable-name convention |
| **[Deployment](./09-deploy.md)** | Phase 5: the wiring graph, the roles that fail silently, `run()` end to end, the pinned terms hash |
| **[Scenarios](./10-scenarios.md)** | Phase 6: end-to-end sequences over the composed system |
| **[Invariant Suite](./11-invariants.md)** | Phase 6 and review: the handler, twelve invariants, revert classification, and the holder-count bug it found |
| **[Gaps & Roadmap](./12-gaps-and-roadmap.md)** | What is open, what is an accepted limitation, what the review closed |
| **[Dividend Distributor](./13-dividend-distributor.md)** | Phase 8: the accumulator identity, the rounding rule that keeps it solvent, the two bugs the suite found, and the integration scenarios |
| **[Regressions](./14-regressions.md)** | Review: one test per bug the review found, grouped by finding |
| **[Edge Cases](./15-edge-cases.md)** | Review: interactions between mechanisms and extreme values |
| **[Conformance](./16-conformance.md)** | Review: ERC-20, ERC-3643, ERC-1643 and EIP-712, with each documented difference asserted |

The files are numbered in the order they were first written, so the review suites come after the gaps register; the numbering is kept because other documents link to these pages by name.

---

## Current Status

`forge test` runs **421 tests in 18 suites**: 387 concrete tests, 22 fuzz tests and 12 stateful invariants. By area: 9 unit suites (297 concrete + 22 fuzz), 4 scenario suites (55), 4 conformance suites (34) and 1 invariant suite (12 invariants + 1 deterministic test). The 10 gas benchmarks in `test/gas/` are not part of the suite: the default and `ci` profiles exclude them, and they run with `FOUNDRY_PROFILE=gas forge test --isolate --gas-report`.

Every test is catalogued exactly once, in the page for its suite.

| Suite | Layer | Concrete | Fuzz | Page |
| :---- | :---- | -------: | ---: | :--- |
| [`SecurityTokenTest`](../../test/unit/SecurityToken.t.sol) | Unit | 61 | 3 | [Security Token](./07-security-token.md) |
| [`IdentityRegistryTest`](../../test/unit/IdentityRegistry.t.sol) | Unit | 44 | 4 | [Identity Registry](./02-identity-registry.md) |
| [`DividendDistributorTest`](../../test/unit/DividendDistributor.t.sol) | Unit | 42 | 5 | [Dividend Distributor](./13-dividend-distributor.md) |
| [`ModularComplianceTest`](../../test/unit/ModularCompliance.t.sol) | Unit | 36 | 2 | [Modular Compliance](./03-modular-compliance.md) |
| [`LockupModuleTest`](../../test/unit/LockupModule.t.sol) | Unit | 31 | 2 | [Lockup Module](./04-lockup-module.md) |
| [`MaxHoldersModuleTest`](../../test/unit/MaxHoldersModule.t.sol) | Unit | 29 | 2 | [Max Holders Module](./05-max-holders-module.md) |
| [`DeployTest`](../../test/unit/Deploy.t.sol) | Unit (integration) | 19 | 0 | [Deployment](./09-deploy.md) |
| [`DocumentRegistryTest`](../../test/unit/DocumentRegistry.t.sol) | Unit | 18 | 2 | [Document Registry](./08-document-registry.md) |
| [`CountryRestrictionModuleTest`](../../test/unit/CountryRestrictionModule.t.sol) | Unit | 17 | 2 | [Country Restriction](./06-country-restriction.md) |
| [`RegressionsTest`](../../test/scenario/Regressions.t.sol) | Scenario | 29 | 0 | [Regressions](./14-regressions.md) |
| [`EdgeCasesTest`](../../test/scenario/EdgeCases.t.sol) | Scenario | 12 | 0 | [Edge Cases](./15-edge-cases.md) |
| [`LifecycleTest`](../../test/scenario/Lifecycle.t.sol) | Scenario | 10 | 0 | [Scenarios](./10-scenarios.md) |
| [`DividendsTest`](../../test/scenario/Dividends.t.sol) | Scenario | 4 | 0 | [Dividend Distributor](./13-dividend-distributor.md#integration) |
| [`ERC20ConformanceTest`](../../test/conformance/ERC20Conformance.t.sol) | Conformance | 12 | 0 | [Conformance](./16-conformance.md#erc-20) |
| [`ERC3643ConformanceTest`](../../test/conformance/ERC3643Conformance.t.sol) | Conformance | 10 | 0 | [Conformance](./16-conformance.md#erc-3643) |
| [`ERC1643ConformanceTest`](../../test/conformance/ERC1643Conformance.t.sol) | Conformance | 6 | 0 | [Conformance](./16-conformance.md#erc-1643) |
| [`EIP712ConformanceTest`](../../test/conformance/EIP712Conformance.t.sol) | Conformance | 6 | 0 | [Conformance](./16-conformance.md#eip-712) |
| [`InvariantsTest`](../../test/invariant/Invariants.t.sol) | Invariant | 1 | 0 | [Invariant Suite](./11-invariants.md) (plus 12 invariants) |
| **Total** | | **387** | **22** | **+ 12 invariants = 421** |

Profiles: the default runs 256 fuzz runs per fuzz test and 64 runs of depth 64 per invariant; `FOUNDRY_PROFILE=ci forge test` raises these to 1,000 fuzz runs and 256 runs of depth 128. Two deeper runs are documented: `FOUNDRY_INVARIANT_RUNS=300 FOUNDRY_INVARIANT_DEPTH=100 forge test --match-path 'test/invariant/*'` and `FOUNDRY_FUZZ_RUNS=20000 forge test --match-contract DividendDistributorTest`. See [Strategy, running the suite](./01-strategy.md#4-running-the-suite).

### Coverage

From `forge coverage --report summary`:

| File | Lines | Statements | Branches | Functions |
| :--- | :---- | :--------- | :------- | :-------- |
| `src/SecurityToken.sol` | 110/110 | 130/130 | 36/36 | 18/18 |
| `src/identity/IdentityRegistry.sol` | 52/52 | 54/54 | 7/7 | 14/14 |
| `src/compliance/ModularCompliance.sol` | 55/55 | 76/76 | 13/13 | 13/13 |
| `src/DocumentRegistry.sol` | 19/19 | 21/21 | 6/6 | 5/5 |
| `src/compliance/modules/AbstractComplianceModule.sol` | 21/21 | 21/21 | 3/3 | 8/8 |
| `src/compliance/modules/CountryRestrictionModule.sol` | 24/25 (96.00%) | 21/22 (95.45%) | 3/3 | 11/11 |
| `src/compliance/modules/DividendDistributor.sol` | 59/60 (98.33%) | 68/69 (98.55%) | 10/10 | 16/16 |
| `src/compliance/modules/LockupModule.sol` | 63/64 (98.44%) | 77/78 (98.72%) | 16/16 | 16/16 |
| `src/compliance/modules/MaxHoldersModule.sol` | 46/47 (97.87%) | 71/72 (98.61%) | 12/12 | 12/12 |
| `script/Deploy.s.sol` | 61/61 | 62/62 | 15/29 (51.72%) | 6/6 |

In each of the four modules the one unmarked line is the constant return of a `pure` view (`isPlugAndPlay` or `token`) that the unit tests call and assert. The 14 untaken `Deploy.s.sol` branches are the failure sides of the `require` checks in `_verify`. Both are explained in [Gaps & Roadmap](./12-gaps-and-roadmap.md#coverage-is-not-complete-on-every-metric).

---

## Invariant Coverage Map

Every invariant from [Guide 5, Section 7](../05-implementation.md#7-invariants), plus the two dividend properties that are not stateful invariants, and what asserts each. The stateful entries hold across arbitrary interleavings of the fifteen handler actions (the handler does not add or remove modules, see [Gaps](./12-gaps-and-roadmap.md#module-addition-and-removal-are-not-in-the-invariant-handler)); the rest are pinned at points by the unit and scenario suites.

| Property | Statement | Stateful invariant | Point tests |
| :------- | :-------- | :----------------- | :---------- |
| **Supply conservation** | `Σ balanceOf == totalSupply` | [`invariant_balancesSumToTotalSupply`](../../test/invariant/Invariants.t.sol#L126) | [`testFuzz_transferConservesSupply`](../../test/unit/SecurityToken.t.sol#L871) |
| **Supply moves only by mint and burn** | Recovery, transfers, freezes and identity changes never change `totalSupply` | [`invariant_supplyMatchesMintsMinusBurns`](../../test/invariant/Invariants.t.sol#L138) | [`testFuzz_recoveryConservesSupply`](../../test/unit/SecurityToken.t.sol#L884), [`test_scenario_compromisedKeyRecoveredUnderPause`](../../test/scenario/Lifecycle.t.sol#L137) |
| **Frozen ≤ balance** | `frozenTokens[a] <= balanceOf(a)` | [`invariant_frozenNeverExceedsBalance`](../../test/invariant/Invariants.t.sol#L151) | Enforced at the write by [`test_freezePartialTokens_revertsAboveBalance`](../../test/unit/SecurityToken.t.sol#L261), preserved on burn by [`test_burn_eatsFrozenWhenExceedingFree`](../../test/unit/SecurityToken.t.sol#L206) |
| **Holder count is exact** | The module's count equals the wallets holding a positive balance | [`invariant_holderCountMatchesReality`](../../test/invariant/Invariants.t.sol#L166), the one that caught the self-transfer bug | [`testFuzz_countMatchesReality`](../../test/unit/MaxHoldersModule.t.sol#L351), the zero-amount regressions under [finding 1](./14-regressions.md#1-zero-amounts-deflated-the-holder-count) |
| **Cap respected** | Holder count never exceeds `maxHolders` | [`invariant_holderCountNeverExceedsCap`](../../test/invariant/Invariants.t.sol#L178) | [`testFuzz_countNeverExceedsCap`](../../test/unit/MaxHoldersModule.t.sol#L386), the lowering guard [`test_setMaxHolders_revertsBelowCurrentCount`](../../test/unit/MaxHoldersModule.t.sol#L324). Forced recovery bypasses the gate but cannot raise the count, since the lost wallet is emptied in the same movement |
| **Verified holders only** | No unverified address can *increase* its balance | [`invariant_unverifiedBalanceNeverGrows`](../../test/invariant/Invariants.t.sol#L220) | [`test_transfer_revertsForUnverifiedRecipient`](../../test/unit/SecurityToken.t.sol#L310), [`test_mint_revertsForUnverifiedRecipient`](../../test/unit/SecurityToken.t.sol#L143), [`test_scenario_withdrawnIdentitySuspendsPosition`](../../test/scenario/Lifecycle.t.sol#L218). **Reformulated:** a holder can become unverified through `removeIdentity` or an expired KYC and keeps the position, so the property is not "no unverified holder exists". See [Security Token](./07-security-token.md#the-transfer-gate-42-43) |
| **Evicted wallets stay empty** | A wallet retired by recovery receives nothing while unverified | No dedicated invariant since the review removed the vacuous `invariant_recoveryLeavesEvictedWalletEmpty`. When the lost wallet was verified until the recovery, `invariant_unverifiedBalanceNeverGrows` records its zero balance at that moment and holds it there | [`test_forcedRecovery_movesFullBalance`](../../test/unit/SecurityToken.t.sol#L660), [`test_scenario_retiredWalletCannotBeUsedAgain`](../../test/scenario/Lifecycle.t.sol#L189) |
| **Lockup clock matches the position** | `lockStart(a) != 0` exactly when `balanceOf(a) != 0` | [`invariant_lockupClockMatchesPosition`](../../test/invariant/Invariants.t.sol#L192) | [`test_mint_startsClock`](../../test/unit/LockupModule.t.sol#L111), [`test_exitToZero_clearsClockAndRelocksOnReentry`](../../test/unit/LockupModule.t.sol#L284), [`test_burnToZero_clearsClock`](../../test/unit/LockupModule.t.sol#L316) |
| **Recovery keeps the lockup start** | After a recovery the destination holds the earlier of the two starts and the lost wallet none | [`invariant_recoveryKeepsLockupStart`](../../test/invariant/Invariants.t.sol#L205) | [`test_recovery_carriesClockToEmptyWallet`](../../test/unit/LockupModule.t.sol#L244), [`test_recovery_keepsDestinationsEarlierStart`](../../test/unit/LockupModule.t.sol#L256), the regressions under [finding 4](./14-regressions.md#4-forced-recovery-restarted-the-lockup) |
| **Dividend solvency** | The distributor holds at least what it reports as owed | [`invariant_dividendsSolvent`](../../test/invariant/Invariants.t.sol#L239) | [`testFuzz_solventAcrossRepeatedDeposits`](../../test/unit/DividendDistributor.t.sol#L693) over up to twenty deposits, [`test_deposit_claimsNeverExceedFundsAcrossManyDeposits`](../../test/unit/DividendDistributor.t.sol#L337) |
| **Dividend conservation** | Claimed plus claimable is never above what was deposited, and at most seven wei below | [`invariant_dividendsConserved`](../../test/invariant/Invariants.t.sol#L250) | [`testFuzz_conservation_claimsNeverExceedDeposits`](../../test/unit/DividendDistributor.t.sol#L640), [`testFuzz_roundingDustIsBounded`](../../test/unit/DividendDistributor.t.sol#L658) |
| **Blocked holders are never paid** | No claim succeeds while the claimant is fully frozen or unverified | [`invariant_blockedHoldersAreNeverPaid`](../../test/invariant/Invariants.t.sol#L259) | [`test_claim_revertsWhileFullyFrozen`](../../test/unit/DividendDistributor.t.sol#L220), [`test_claim_revertsWhileUnverified`](../../test/unit/DividendDistributor.t.sol#L231), the regressions under [finding 5](./14-regressions.md#5-frozen-and-unverified-holders-could-claim-income) |
| **No unexpected reverts** | Every revert the handler catches is one its action may legitimately produce | [`invariant_noUnexpectedReverts`](../../test/invariant/Invariants.t.sol#L272) | [`test_handlerExercisesEveryAction`](../../test/invariant/Invariants.t.sol#L309) shows the classification counting a lockup refusal as expected |
| **Entitlement conserved by transfer** | A transfer changes who is owed, never the total owed | Not a separate invariant; a transfer that moved entitlement would break `invariant_dividendsConserved` | [`testFuzz_transferPreservesTotalEntitlement`](../../test/unit/DividendDistributor.t.sol#L674), plus the mint and burn cases in [Dividend Distributor](./13-dividend-distributor.md#correction-accounting) |
| **Recovery carries the entitlement** | After recovery the lost wallet is owed nothing and the new wallet what it was owed | Not a separate invariant | [`test_recovery_carriesEntitlementToTheNewWallet`](../../test/unit/DividendDistributor.t.sol#L466), [`test_scenario_recoveryCarriesUnclaimedIncome`](../../test/scenario/Dividends.t.sol#L117), [`test_recoveredLostWallet_cannotClaim`](../../test/scenario/EdgeCases.t.sol#L183) |

---

## References

- [Documentation Index](../README.md)
- [Guide 3: Architecture](../03-architecture.md): the transfer gate and the binding graph
- [Guide 4: Trade-offs](../04-tradeoffs.md): accepted risks the tests deliberately do not defend against
- [Guide 5: Implementation](../05-implementation.md): conventions and the invariant table
- [README review notes](../../README.md#review-notes): the findings the regression tests are numbered by
- [ROADMAP](../ROADMAP.md): phase status
