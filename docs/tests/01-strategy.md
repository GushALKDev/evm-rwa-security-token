# Testing Strategy

**Section:** [Testing Documentation](./README.md)
**Next:** [Identity Registry](./02-identity-registry.md)

---

## 1. Layers

The suite is layered, and each layer answers a different question. Counts are from `forge test` on the default profile.

| Layer | Directory | Question it answers | Tests |
| :---- | :-------- | :------------------ | :---- |
| **Unit** | `test/unit/` | Does this contract do exactly what its interface says? | 8 suites, 278 concrete + 22 fuzz |
| **Fuzz** | inline, `testFuzz_` prefix | Does the property hold across the input domain? | 22, inside the unit suites |
| **Integration** | `test/unit/Deploy.t.sol` | Does the deployed system come up wired and usable? | 19 |
| **Scenario** | `test/scenario/` | Does the composed system behave like the instrument, including every bug the review found? | 4 suites, 55 |
| **Conformance** | `test/conformance/` | Does each contract match the standard it claims, and where it differs, is the difference the documented one? | 4 suites, 34 |
| **Invariant** | `test/invariant/` | Do the invariants survive arbitrary call sequencing? | 12 invariants + 1 deterministic test |
| **Gas benchmarks** | `test/gas/` | What does each operation cost? Not a test layer | 10, excluded from the suite |

The unit row counts the eight contract suites; with `DeployTest` the nine unit suites hold 297 concrete and 22 fuzz tests. Fuzz tests live inside the unit suite of the contract they cover rather than in a directory of their own: the properties being fuzzed (a lockup boundary, a holder-count transition) belong to one contract each, so splitting them out would separate a property from the point tests that pin its edges.

The gas benchmarks in [`test/gas/Gas.t.sol`](../../test/gas/Gas.t.sol) are measurements, not tests: they assert nothing about behaviour. The default profile excludes `test/gas/*` through `no_match_path`, the `ci` profile inherits that, and they run only with `FOUNDRY_PROFILE=gas forge test --isolate --gas-report`, where `--isolate` prices each call as its own transaction.

---

## 2. Principles

**Assert the specific error, never a bare revert.** Every negative test names the custom error it expects, with its parameters. A bare `vm.expectRevert()` passes on *any* revert, including one from a completely different guard, so it silently stops testing what it claims to. None remains in the suite: `grep -rn 'vm.expectRevert()' test/` and `grep -rn 'expectRevert("' test/` both return nothing, and `grep -rn 'vm.expectRevert(' test/ | wc -l` counts 172 calls, every one of which passes a custom error selector, alone or encoded with its parameters.

**Match the selector alone only where a parameter cannot or need not be pinned.** Where a parameter is unpredictable, such as the address recovered from a tampered or stale signature in `InvalidAttestationSigner`, `vm.expectPartialRevert` matches the selector rather than dropping the assertion. Several scenario and deployment tests also match the `ComplianceCheckFailed` selector alone. `grep -rn 'expectPartialRevert' test/ | wc -l` counts 25 uses.

**Bound rounding in one direction, and say why.** The dividend arithmetic truncates on purpose: each holder's payout is descaled with a floor, so it may fall short of the exact share by less than one wei and must never exceed it. Payout assertions therefore use a one-sided helper, `_assertOwed(actual, expected)`, which checks `actual <= expected` and `actual + 1 >= expected`. An exact-equality assertion would pin a rounding outcome the design does not promise, and a symmetric tolerance would accept an overpayment, which is a solvency bug. The same rule scales with the number of accounts: two wei for two holders in the fuzz tests, seven wei for six accounts plus the carried residue in [`invariant_dividendsConserved`](../../test/invariant/Invariants.t.sol#L250), and zero tolerance in the direction of paying more than was deposited.

**Verify claims, do not assert them.** Storage reads are measured rather than described: [`test_isVerified_readsOneStorageSlot`](../../test/unit/IdentityRegistry.t.sol#L423) records the slots `isVerified` touches. The anchored document hash is recomputed from the file on disk and compared with a hash pinned independently in the test, so an edited terms document and a stale anchor cannot silently agree. Where this catalogue states a behaviour, a linked test shows it.

**Test the powerful operations by what they cannot do.** `forcedRecovery` moves an arbitrary balance between wallets, so most of its tests are negative: it cannot cross investors, cannot change total supply, cannot launder a freeze, cannot be reentered. The same applies to the role split, where the interesting assertion is that AGENT *cannot* recover.

**Separate a suspension from a seizure.** Several mechanisms stop tokens moving (pause, full freeze, partial freeze, withdrawn identity). For each, a test pins that the balance survives and that the measure is reversible, because the failure mode worth catching is a compliance control that quietly destroys value.

**Fuzz where the input space is large, point-test where the edge is exact.** The lockup boundary is fuzzed across periods and elapsed times, *and* point-tested at one second before, exactly at, and after expiry. Fuzzing alone tends to miss the exact boundary; point tests alone do not establish the property. Where the interesting inputs are specific values (zero, the full balance, one wei), the fuzz tests and the invariant handler draw amounts **by mode** so those values occur in most runs.

**Pin documented limitations as tests.** Where the system deliberately does not defend against something (a `transferFrom` spender is not checked, a contract cannot be the claim signer, a pause does not stop administration), a test asserts the actual behaviour and its comment says so. If the behaviour changes, the test fails and the documentation has to change with it.

**Check the tests against the bugs.** In the review, bugs 1 to 12 of the README's review notes, and hardening entries 1 and 3, were reintroduced into the code to confirm that at least one test fails without the fix. Bug 13 (in the deployment script), the defect introduced during the review and the terms wording were not checked that way. A regression test that passes against the unfixed code tests nothing.

**Mocks isolate the unit under test; the scenarios use none.** [`MockModule`](../../test/helpers/MockModule.sol) is a real `AbstractComplianceModule` with a toggleable verdict and hook counters, so a token test can force a compliance rejection without depending on any real rule's semantics. The scenario, conformance and deployment suites wire the *real* modules, so the integration is shown separately from the isolation.

---

## 3. Infrastructure

Shared scaffolding lives in [`test/helpers/`](../../test/helpers).

| File | Role |
| :--- | :--- |
| [`MockModule.sol`](../../test/helpers/MockModule.sol) | `MockModule`: a minimal compliance module extending the real `AbstractComplianceModule`, so the production `onlyCompliance` gate is the one under test. Its verdict is toggled with `setAllow`, every lifecycle hook is counted, and `setToken` sets what `token()` reports. Plug and play |
| `StatefulMockModule` (same file) | The same module reporting not plug and play, so the engine may attach it only once |
| `WrongEngineModule` (same file) | A module bound to a different engine, used to exercise the `ModuleNotBound` guard in `addModule` |
| `ReenteringModule` (same file) | A module that, once armed, makes one reentrant call from inside the transfer hook and records whether it was attempted and how it ended. Used for the recovery reentrancy test |
| [`MockToken.sol`](../../test/helpers/MockToken.sol) | A minimal ERC-20 with open `mint`/`burn`, used by the module suites to drive balances directly. It also answers the few token queries the modules make, each settable from the test: `recovering()`, `isFrozen()`, and `isVerified()` through `identityRegistry()` pointing back at itself |
| [`MockCurrency.sol`](../../test/helpers/MockCurrency.sol) | A 6-decimal ERC-20 standing in for the settlement currency, matching a stablecoin rather than the 18-decimal token |

Three hostile doubles live in the suite that uses them: `ReenteringCurrency` in the dividend unit suite (reenters `claim` or `deposit` from the currency's own transfer), `FlakyCurrency` in the edge-case suite (returns `false` or reverts on transfers), and `SignerStub` in the EIP-712 suite (a contract that would approve any signature under EIP-1271).

The scenario, conformance (ERC-20 and ERC-3643) and deployment suites use no mocks for the system under test: they inherit [`Deploy`](../../script/Deploy.s.sol) and call `_deploy` directly, so they run against the same wiring a real deployment produces. Duplicating the construction order in a test fixture would mean the fixture and the script could drift, and the drift would be invisible. The invariant suite is the one exception, wired by hand for the reasons given in [its configuration](./11-invariants.md#configuration).

---

## 4. Running the Suite

```bash
forge test                                         # the full suite, default profile
forge test --match-path 'test/scenario/*'          # one layer
forge test --match-test test_forcedRecovery        # one behaviour, across suites
forge coverage --report summary                    # per-contract coverage
forge fmt --check                                  # formatting gate
FOUNDRY_PROFILE=gas forge test --isolate --gas-report   # gas benchmarks only
```

| Profile | Fuzz runs | Invariant runs x depth | Source |
| :------ | --------: | :--------------------- | :----- |
| default | 256 | 64 x 64 | `[fuzz]` and `[invariant]` in `foundry.toml` |
| `ci` | 1,000 | 256 x 128 | `[profile.ci]`, run by CI as `FOUNDRY_PROFILE=ci` |

Both profiles set `fail_on_revert = false` for the invariant suite, which is why the handler classifies its own reverts ([revert classification](./11-invariants.md#revert-classification)). CI ([`.github/workflows/test.yml`](../../.github/workflows/test.yml)) runs `forge fmt --check`, `forge build --sizes` and `forge test -vvv` under the `ci` profile.

Two deeper runs are documented for changes to a stateful module or to the dividend arithmetic:

```bash
FOUNDRY_INVARIANT_RUNS=300 FOUNDRY_INVARIANT_DEPTH=100 forge test --match-path 'test/invariant/*'
FOUNDRY_FUZZ_RUNS=20000 forge test --match-contract DividendDistributorTest
```

---

## 5. What the review changed in the tests

Besides the regression tests for each bug ([Regressions](./14-regressions.md)), the review found problems in the tests themselves. The README lists them as test-suite findings; this is where each one landed in the catalogue.

| Finding (README wording) | Where the change is documented |
| :----------------------- | :----------------------------- |
| The invariant handler caught every revert, so failures were invisible; two invariants could not fail | [Invariant Suite, what the review changed](./11-invariants.md#what-the-review-changed) |
| A bare `vm.expectRevert()`; the signer fuzz test only tested rejection | Principle 1 above; [`testFuzz_registerWithAttestation_onlyClaimSignerAccepted`](../../test/unit/IdentityRegistry.t.sol#L627) |
| The reentrancy test did not show a reentry was attempted; `deposit` and `forcedRecovery` had no reentrancy test | [`test_claim_isReentrancyGuarded`](../../test/unit/DividendDistributor.t.sol#L593), [`test_deposit_isReentrancyGuarded`](../../test/unit/DividendDistributor.t.sol#L615), [`test_forcedRecovery_isReentrancyGuarded`](../../test/unit/SecurityToken.t.sol#L835) |
| The 1-wei re-lock test dusted after expiry; the holder-count fuzz never transferred | [`test_griefing_oneWeiCannotRelockPosition`](../../test/unit/LockupModule.t.sol#L193), [`testFuzz_countMatchesReality`](../../test/unit/MaxHoldersModule.t.sol#L351) |
| Engine and document tests checked less than their names said | [Modular Compliance, lifecycle hooks](./03-modular-compliance.md#lifecycle-hooks), [`test_removeThenSet_reindexes`](../../test/unit/DocumentRegistry.t.sol#L170), [`testFuzz_indexCountsDistinctNames`](../../test/unit/DocumentRegistry.t.sol#L241) |
| The composed-rules scenario could not tell the lockup from the country rule | [`test_scenario_everyRuleMustPassIndependently`](../../test/scenario/Lifecycle.t.sol#L376) |
| Dividend fuzz bounds excluded small supplies; `uint96` parameters were truncated; exact rounding asserted | [Dividend Distributor, fuzz](./13-dividend-distributor.md#fuzz), principle 3 above |
| Suite not runnable under `forge coverage` (stack too deep) | The handler's wiring is grouped in a `System` struct; the slot test counts distinct slots |

One test still does less than its name: [`test_pause_haltsMintAndBurn`](../../test/unit/SecurityToken.t.sol#L427) asserts only the mint. The burn under pause is asserted in [`test_pause_againstEachRoleAction`](../../test/scenario/EdgeCases.t.sol#L289), and the catalogue row says so.

---

## 6. Conventions in the test code

- **Named sections.** Every suite is divided by the same banner comments used in `src/`, grouping tests by the behaviour they cover rather than by assertion type.
- **`test_` for point tests, `testFuzz_` for properties, `invariant_` for stateful properties.** The prefix says whether the test pins a case or a property.
- **Helpers over repetition.** Each suite defines the two or three helpers its scenarios need (`_verify`, `_mint`, `_passLockup`, `_assertOwed`), so the body of a test reads as the sequence being tested, not as setup. Module suites mirror the engine: the helper moves the balance first and then fires the hook, as the token does.
- **A comment on every non-obvious test.** Where a test exists because of a specific failure mode (a griefing vector, a replay window, a rule that must *not* apply, a review finding), a `@dev` comment states the reasoning. Those comments are the source for most of this documentation.
