# Scenarios (Phase 6)

**Suites:** [`LifecycleTest`](../../test/scenario/Lifecycle.t.sol) (10 scenario)
**Covers:** roadmap item 6.1 · [Guide 3, the transfer gate](../03-architecture.md#4-the-transfer-gate-a-superset-check)

---

> Nothing is mocked here. The system is the one [`Deploy`](../../script/Deploy.s.sol) produces, with the real engine, the real registry and all three rule modules registered at the real 365-day lockup. Each test is a **sequence** rather than a single call, because the failures worth catching at this level live in the ordering: a freeze that must survive a recovery, a lockup clock a partial exit must not reset, a holder seat that only frees when a wallet fully empties. None of those are observable from one transaction, which is why the unit suites cannot reach them.

## 1. The ordinary life of a note

| Test | Asserts |
| :--- | :------ |
| [`test_scenario_subscribeHoldTradeRedeem`](../../test/scenario/Lifecycle.t.sol#L77) | Onboard, subscribe, be blocked by the lockup, trade once free, be partially redeemed. Holder count and supply tracked at each step |
| [`test_scenario_lockupFollowsTheAcquisition`](../../test/scenario/Lifecycle.t.sol#L110) | A buyer inherits a **fresh** lockup on what they receive, even from a seller whose own period had expired |

The first is the path every holder is expected to walk, and the property under test is that it needs **no privileged intervention** beyond issuance itself: no agent unfreezing anything, no custodian involvement, no module reconfiguration. A permissioned token that requires an operator to intervene in the ordinary case is not a tradeable instrument.

The second pins the lockup as a property of the *acquisition* rather than of the wallet or the tokens. That is what stops a position being laundered clean by passing it through a third party — the recipient's own clock starts on receipt, so the holding period restarts rather than transferring.

---

## 2. Incident and recovery

| Test | Asserts |
| :--- | :------ |
| [`test_scenario_compromisedKeyRecoveredUnderPause`](../../test/scenario/Lifecycle.t.sol#L137) | The full incident: a partial hold is in place, the desk pauses, the custodian relocates the position, the hold travels, supply is unchanged, and after unpausing only the unfrozen part moves |
| [`test_scenario_retiredWalletCannotBeUsedAgain`](../../test/scenario/Lifecycle.t.sol#L189) | The compromised wallet is **barred**, not merely emptied: it cannot receive again |

The first is the scenario the instrument exists to survive, and it is the densest test in the suite because every exemption in the system converges on it. Recovery must work **while paused** (the halt is the response to this very incident) and **while the lockup is still running** (a compromise does not wait for a holding period). The freeze must travel rather than being dropped, or recovery would launder an operational hold. Supply must be unchanged, or recovery would be issuance. And afterwards the pause must still be in force for everyone else.

The second closes the loop on eviction: `forcedRecovery` calls `removeIdentity`, so the lost wallet fails the identity gate from that point on. Without it, a compromised key could keep receiving transfers from unwitting counterparties.

---

## 3. Sanction

| Test | Asserts |
| :--- | :------ |
| [`test_scenario_withdrawnIdentitySuspendsPosition`](../../test/scenario/Lifecycle.t.sol#L218) | A holder who loses their identity can neither sell out nor be topped up, their balance is untouched throughout, and the issuer can still lawfully retire it by burning |
| [`test_scenario_reverificationReleasesPosition`](../../test/scenario/Lifecycle.t.sol#L250) | Re-verifying releases the position, so the measure is reversible |

`removeIdentity` is what compliance reaches for when an investor may no longer hold the instrument at all. The scenario asserts all three properties that make it a **suspension rather than a seizure**: movement stops in both directions, the balance survives, and compliance can undo it. The burn at the end matters too — it shows the lawful exit remains open, so a suspended position is not permanently stranded.

This is the end-to-end counterpart of the sender-side identity check documented under [the transfer gate](./07-security-token.md#the-transfer-gate-42-43).

---

## 4. The holder cap

| Test | Asserts |
| :--- | :------ |
| [`test_scenario_capRefusesNewHolderThenAdmitsReplacement`](../../test/scenario/Lifecycle.t.sol#L275) | A full placement refuses a new subscriber; once a seat frees, the same subscriber is admitted |
| [`test_scenario_replacementAtCapIsAllowed`](../../test/scenario/Lifecycle.t.sol#L305) | A transfer that empties the sender while filling a new holder is allowed even at the cap |

Together these establish that the cap limits **concurrent holders, not participation over time**. A cap that refused the replacement would freeze a full placement permanently: no investor could ever enter again, even as others exited completely.

---

## 5. Jurisdiction

| Test | Asserts |
| :--- | :------ |
| [`test_scenario_closingAJurisdictionBlocksInboundOnly`](../../test/scenario/Lifecycle.t.sol#L334) | After closing a country, nothing more can be distributed into it, but the holder already there can still sell out |

A distribution restriction governs who the instrument may be **placed with**. Trapping existing holders would be a different measure with different legal meaning, and it is not what this module does — immobilising a specific position is the freeze and recovery machinery's job, which is targeted and auditable rather than a side effect of a jurisdiction list.

---

## 6. Rules compose, not override

| Test | Asserts |
| :--- | :------ |
| [`test_scenario_everyRuleMustPassIndependently`](../../test/scenario/Lifecycle.t.sol#L371) | Three blockers are stacked on one transfer and lifted one at a time, asserting a **different rejection at each step** and success only after the last is cleared |

The single most useful test in the suite. It stacks a partial freeze, an unexpired lockup and a closed jurisdiction on the same transfer, then removes them in sequence: freeze released (still blocked, now by the lockup), lockup elapsed (still blocked, now by the country rule), jurisdiction reopened (settles).

What it proves is that the rules compose as a strict **AND** and that none of them masks another. A unit test can show each rule rejects in isolation; only a sequence like this can show that clearing one does not accidentally clear the others, or that the gate does not short-circuit on the first check and skip the rest. It is also the test most likely to catch a regression in the ordering of `_checkTransfer`, since each step asserts a specific error rather than merely "it reverted".
