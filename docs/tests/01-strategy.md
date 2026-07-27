# 🎯 Testing Strategy

**Section:** [Testing Documentation](./README.md)
**Next:** [Identity Registry](./02-identity-registry.md)

---

## 1. Layers

The suite is layered, and each layer answers a different question.

| Layer | Directory | Question it answers | Status |
| :---- | :-------- | :------------------ | :----- |
| **Unit** | `test/unit/` | Does this contract do exactly what its interface says? | ✅ Phases 1-5 |
| **Fuzz** | inline, `testFuzz_` prefix | Does the property hold for every input in the domain? | ✅ Phases 1-4 |
| **Integration** | `test/unit/Deploy.t.sol` | Does the deployed system come up wired and usable? | ✅ Phase 5 |
| **Scenario** | `test/scenario/` | Does the composed system behave like the instrument? | ✅ Phase 6 |
| **Invariant** | `test/invariant/` | Do the invariants survive adversarial call sequencing? | ⬜ Phase 6.2/6.3 |

Fuzz tests live inside the unit suite of the contract they cover rather than in a directory of their own. The properties being fuzzed here (a lockup boundary, a holder-count transition) belong to one contract each, so splitting them out would separate a property from the point tests that pin its edges.

---

## 2. Principles

**Assert the specific selector, never a bare revert.** Every negative test names the custom error it expects, with its parameters. A bare `vm.expectRevert()` passes on *any* revert, including one from a completely different guard, so it silently stops testing what it claims to. Where a parameter is genuinely unpredictable — the address recovered from a tampered signature — `expectPartialRevert` matches the selector alone rather than dropping the assertion entirely.

**Verify claims, do not assert them.** Storage packing is checked against `forge inspect storageLayout` rather than asserted in prose. The anchored document hash is recomputed from the file on disk in the test itself, so an edited terms document and a stale anchor cannot silently agree. Where this guide states a behaviour, a linked test proves it.

**Test the powerful operations by what they cannot do.** `forcedRecovery` moves an arbitrary balance between wallets, so most of its tests are negative: it cannot cross investors, cannot change total supply, cannot launder a freeze. The positive path is one test; the boundary is a dozen. The same applies to the role split, where the interesting assertion is that AGENT *cannot* recover.

**Separate a suspension from a seizure.** Several mechanisms stop tokens moving (pause, full freeze, partial freeze, withdrawn identity). For each, a test pins that the balance survives and that the measure is reversible, because the failure mode worth catching is a compliance control that quietly destroys value.

**Fuzz where the input space is large, point-test where the edge is exact.** The lockup boundary is fuzzed across periods and elapsed times, *and* point-tested at one second before, exactly at, and after expiry. Fuzzing alone tends to miss the exact boundary; point tests alone do not establish the property.

**Mocks isolate the unit under test.** [`MockModule`](../../test/helpers/MockModule.sol) is a real `AbstractComplianceModule` with a toggleable verdict and hook counters, so a token test can force a compliance rejection without depending on any real rule's semantics. The scenario suite then wires the *real* modules in, so the integration is proven separately from the isolation.

---

## 3. Infrastructure

Shared scaffolding lives in [`test/helpers/`](../../test/helpers).

| File | Role |
| :--- | :--- |
| [`MockModule.sol`](../../test/helpers/MockModule.sol) | A minimal compliance module extending the real `AbstractComplianceModule`, so the production `onlyCompliance` gate is the one under test. Its verdict is toggled with `setAllow`, and every lifecycle hook is counted, which lets a test assert both that the engine short-circuits a rejection and that it fans each event to every module. |
| `WrongEngineModule` (same file) | A module bound to a different engine, used to exercise the `ModuleNotBound` guard in `addModule`. Its existence is the test: a module pointing elsewhere must be refused at registration. |
| [`MockToken.sol`](../../test/helpers/MockToken.sol) | A minimal ERC20 with open `mint`/`burn`, used by the module suites to drive balances directly. The rule modules read `balanceOf` to decide holder transitions, so they can be tested without the full token and its gate. |

The scenario and deployment suites use no mocks at all: both inherit [`Deploy`](../../script/Deploy.s.sol) and call `_deploy` directly, so they run against the same wiring a real deployment produces. This is deliberate — a test that mocks the thing being deployed cannot catch a wiring mistake.

**Why the suites inherit the deploy script.** Duplicating the construction order in a test fixture would mean the fixture and the script could drift, and the drift would be invisible: the tests would keep passing against a wiring nobody deploys. Inheriting means a change to the deployment order breaks the scenario tests immediately.

---

## 4. Running the Suite

```bash
forge test                                   # the full suite
forge test --match-path test/scenario/*      # one layer
forge test --match-test test_forcedRecovery  # one behaviour, across suites
forge coverage --no-match-coverage "test/"   # per-contract coverage
forge fmt --check                            # formatting gate
```

The `ci` profile in `foundry.toml` raises fuzz runs to 1000 and enables invariant runs, and is the pre-merge gate:

```bash
FOUNDRY_PROFILE=ci forge test
```

---

## 5. Conventions in the test code

- **Named sections.** Every suite is divided by the same banner comments used in `src/`, grouping tests by the behaviour they cover rather than by assertion type.
- **`test_` for point tests, `testFuzz_` for properties.** The prefix says whether the test pins a case or a property.
- **Helpers over repetition.** Each suite defines the two or three helpers its scenarios need (`_verify`, `_mint`, `_passLockup`), so the body of a test reads as the sequence being tested, not as setup.
- **A comment on every non-obvious test.** Where a test exists because of a specific failure mode (a griefing vector, a replay window, a rule that must *not* apply), a `@dev` comment states the reasoning. Those comments are the source for most of this documentation.
