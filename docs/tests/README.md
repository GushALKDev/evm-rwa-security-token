# 🧪 Testing Documentation

**Version:** 1.0
**Prerequisites:** [Guide 3: Architecture](../03-architecture.md)
**Status:** Updated at the close of every roadmap phase (current: Phase 6 complete)

---

> This section is the executable counterpart of [Guide 5, Section 7](../05-implementation.md#7-invariants). Guide 5 states the invariants; this documents which test asserts each one, why the assertion is shaped the way it is, and links every entry to the code.

---

## 📖 Contents

| Document | Covers |
| :------- | :----- |
| **[Strategy](./01-strategy.md)** | Test layers, principles, infrastructure and mocks, how to run the suite |
| **[Identity Registry](./02-identity-registry.md)** | Phase 1: the two registration doors, replay closed on three axes, investor identity, expiry, claim-signer rotation |
| **[Modular Compliance](./03-modular-compliance.md)** | Phase 2: module admin, the AND across modules, module integrity at registration, hook fan-out and gating |
| **[Lockup Module](./04-lockup-module.md)** | Phase 2: the clock state machine, the boundary to the second, and the one-wei griefing guard |
| **[Max Holders Module](./05-max-holders-module.md)** | Phase 2: incremental counting without enumeration, replacement at cap, the cap-lowering guard |
| **[Country Restriction](./06-country-restriction.md)** | Phase 2: recipient-side jurisdiction blocking, and why a restricted sender may still exit |
| **[Security Token](./07-security-token.md)** | Phase 4: the transfer gate, freeze and burn arithmetic, pause, and forced recovery |
| **[Document Registry](./08-document-registry.md)** | Phase 3: content-hash anchoring, amendment as upsert, the readable-name convention |
| **[Deployment](./09-deploy.md)** | Phase 5: the wiring graph, the roles that fail silently, and the anchored hash |
| **[Scenarios](./10-scenarios.md)** | Phase 6: end-to-end sequences over the composed system |
| **[Invariant Suite](./11-invariants.md)** | Phase 6: the bounded handler, seven invariants across arbitrary sequences, and the holder-count bug it found |
| **[Gaps & Roadmap](./12-gaps-and-roadmap.md)** | What is not covered yet, and which phase brings it |

---

## 📊 Current Status

**258 tests, all green.** Every contract under `src/` is at 100% line, statement, branch and function coverage. The handler-based invariant suite is live, and found a real bug on its first high-effort run (see [Invariant Suite](./11-invariants.md)).

| Suite | Layer | Tests | Phase |
| :---- | :---- | ----: | :---- |
| [`IdentityRegistryTest`](../../test/unit/IdentityRegistry.t.sol) | Unit + Fuzz | 44 | 1 |
| [`SecurityTokenTest`](../../test/unit/SecurityToken.t.sol) | Unit + Fuzz | 59 | 4 |
| [`ModularComplianceTest`](../../test/unit/ModularCompliance.t.sol) | Unit + Fuzz | 28 | 2 |
| [`LockupModuleTest`](../../test/unit/LockupModule.t.sol) | Unit + Fuzz | 28 | 2 |
| [`MaxHoldersModuleTest`](../../test/unit/MaxHoldersModule.t.sol) | Unit + Fuzz | 27 | 2 |
| [`DocumentRegistryTest`](../../test/unit/DocumentRegistry.t.sol) | Unit + Fuzz | 20 | 3 |
| [`CountryRestrictionModuleTest`](../../test/unit/CountryRestrictionModule.t.sol) | Unit + Fuzz | 17 | 2 |
| [`DeployTest`](../../test/unit/Deploy.t.sol) | Integration | 15 | 5 |
| [`LifecycleTest`](../../test/scenario/Lifecycle.t.sol) | Scenario | 10 | 6 |
| [`InvariantsTest`](../../test/invariant/Invariants.t.sol) | Invariant | 8 | 6 |
| **Total** | | **258** | |

### Coverage

| File | Lines | Statements | Branches | Functions |
| :--- | :---- | :--------- | :------- | :-------- |
| `src/SecurityToken.sol` | 100.00% (102/102) | 100.00% (123/123) | 100.00% (32/32) | 100.00% (17/17) |
| `src/identity/IdentityRegistry.sol` | 100.00% (45/45) | 100.00% (47/47) | 100.00% (7/7) | 100.00% (14/14) |
| `src/compliance/ModularCompliance.sol` | 100.00% (41/41) | 100.00% (53/53) | 100.00% (9/9) | 100.00% (12/12) |
| `src/compliance/modules/LockupModule.sol` | 100.00% (46/46) | 100.00% (52/52) | 100.00% (10/10) | 100.00% (13/13) |
| `src/compliance/modules/MaxHoldersModule.sol` | 100.00% (42/42) | 100.00% (62/62) | 100.00% (11/11) | 100.00% (10/10) |
| `src/compliance/modules/CountryRestrictionModule.sol` | 100.00% (20/20) | 100.00% (18/18) | 100.00% (2/2) | 100.00% (9/9) |
| `src/compliance/modules/AbstractComplianceModule.sol` | 100.00% (7/7) | 100.00% (6/6) | 100.00% (2/2) | 100.00% (3/3) |
| `src/DocumentRegistry.sol` | 100.00% (19/19) | 100.00% (21/21) | 100.00% (6/6) | 100.00% (5/5) |

`script/Deploy.s.sol` sits at ~61%: the tests call `_deploy` directly, leaving `run()` and the address logging uncovered. Covering a script's `console2.log` calls would not be meaningful. See [Gaps & Roadmap](./12-gaps-and-roadmap.md).

---

## 🔗 Invariant Coverage Map

Every invariant from [Guide 5, Section 7](../05-implementation.md#7-invariants), and what asserts it. The stateful entries hold across arbitrary interleavings of every state-mutating entry point; the rest are pinned at points by the unit and scenario suites.

| Invariant | Statement | Asserted by |
| :-------- | :-------- | :---------- |
| **Supply conservation** | `Σ balanceOf == totalSupply` | Stateful: [`invariant_balancesSumToTotalSupply`](../../test/invariant/Invariants.t.sol#L108) across sequences, plus [`testFuzz_transferConservesSupply`](../../test/unit/SecurityToken.t.sol#L735) |
| **Recovery preserves supply** | `forcedRecovery` never changes `totalSupply` | Stateful: [`invariant_supplyMatchesMintsMinusBurns`](../../test/invariant/Invariants.t.sol#L121), tracking supply against ghost mint/burn counters, plus [`testFuzz_recoveryConservesSupply`](../../test/unit/SecurityToken.t.sol#L748) and [`test_scenario_compromisedKeyRecoveredUnderPause`](../../test/scenario/Lifecycle.t.sol#L137) |
| **Frozen ≤ balance** | `frozenTokens[a] <= balanceOf(a)` | Stateful: [`invariant_frozenNeverExceedsBalance`](../../test/invariant/Invariants.t.sol#L135). Enforced at the write by [`test_freezePartialTokens_revertsAboveBalance`](../../test/unit/SecurityToken.t.sol#L259) and preserved on burn by [`test_burn_eatsFrozenWhenExceedingFree`](../../test/unit/SecurityToken.t.sol#L204) |
| **Holder count is exact** | The module's count equals the addresses holding a positive balance | Stateful: [`invariant_holderCountMatchesReality`](../../test/invariant/Invariants.t.sol#L151) — **this is the one that caught the self-transfer bug** — plus [`testFuzz_countMatchesReality`](../../test/unit/MaxHoldersModule.t.sol#L318) |
| **Cap respected** | Holder count never exceeds `maxHolders` | Stateful: [`invariant_holderCountNeverExceedsCap`](../../test/invariant/Invariants.t.sol#L164), plus [`testFuzz_countNeverExceedsCap`](../../test/unit/MaxHoldersModule.t.sol#L339) and the lowering guard [`test_setMaxHolders_revertsBelowCurrentCount`](../../test/unit/MaxHoldersModule.t.sol#L294). **Note:** forced recovery bypasses the gate, but cannot raise the count, since the lost wallet is always emptied in the same movement |
| **Verified holders only** | No unverified address can *increase* its balance | Stateful: [`invariant_unverifiedHoldersAreConsistent`](../../test/invariant/Invariants.t.sol#L204), plus [`test_transfer_revertsForUnverifiedRecipient`](../../test/unit/SecurityToken.t.sol#L308) and [`test_mint_revertsForUnverifiedRecipient`](../../test/unit/SecurityToken.t.sol#L141). **Reformulated:** an existing holder *can* become unverified via `removeIdentity`, which suspends the position rather than removing it, so the property is not "no unverified holder exists". See [Security Token](./07-security-token.md#the-transfer-gate-42-43) |
| **Evicted wallets stay empty** | A wallet retired by recovery holds nothing while unverified | Stateful: [`invariant_recoveryLeavesEvictedWalletEmpty`](../../test/invariant/Invariants.t.sol#L183), plus [`test_scenario_retiredWalletCannotBeUsedAgain`](../../test/scenario/Lifecycle.t.sol#L189) |

---

## 📚 References

- [Documentation Index](../README.md)
- [Guide 3: Architecture](../03-architecture.md) — the transfer gate and the binding graph
- [Guide 4: Trade-offs](../04-tradeoffs.md) — accepted risks the tests deliberately do not defend against
- [Guide 5: Implementation](../05-implementation.md) — conventions and the invariant table
- [ROADMAP](../ROADMAP.md) — phase status
