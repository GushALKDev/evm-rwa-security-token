# Scenarios (Phase 6)

**Suites:** [`LifecycleTest`](../../test/scenario/Lifecycle.t.sol) (10 scenario)
**Covers:** roadmap item 6.1 · [Guide 3, the transfer gate](../03-architecture.md#4-the-transfer-gate-a-superset-check)

---

> Nothing is mocked here. The system is the one [`Deploy`](../../script/Deploy.s.sol) produces, with the real engine, the real registry and all three rule modules registered at the real 365-day lockup. Each test is a **sequence** rather than a single call, because the failures worth catching at this level live in the ordering: a freeze that must survive a recovery, a lockup clock a partial exit must not reset, a holder seat that only frees when a wallet fully empties. None of those are observable from one transaction, which is why the unit suites cannot reach them.

The other scenario suites run against the same deployment: [`DividendsTest`](./13-dividend-distributor.md#integration) (income through the real engine), [`RegressionsTest`](./14-regressions.md) (one test per review finding) and [`EdgeCasesTest`](./15-edge-cases.md) (boundaries and griefing vectors).

## 1. The ordinary life of a note

| Test | Asserts |
| :--- | :------ |
| [`test_scenario_subscribeHoldTradeRedeem`](../../test/scenario/Lifecycle.t.sol#L77) | Onboard and subscribe (holder count 1), be refused a transfer inside the lockup (`ComplianceCheckFailed`), trade half once the period has run (count 2), be partially redeemed by the issuer (supply falls, count stays 2) |
| [`test_scenario_lockupFollowsTheAcquisition`](../../test/scenario/Lifecycle.t.sol#L110) | A buyer who receives from a seller whose own period had expired is still refused a transfer onward: the buyer's own clock is running |

The first is the path every holder is expected to walk, and the property under test is that it needs **no privileged intervention** beyond issuance and redemption: no agent unfreezing anything, no custodian involvement, no module reconfiguration.

The second pins the lockup as a property of the *acquisition* rather than of the wallet or the tokens. That is what stops a position being freed by passing it through a third party.

---

## 2. Incident and recovery

| Test | Asserts |
| :--- | :------ |
| [`test_scenario_compromisedKeyRecoveredUnderPause`](../../test/scenario/Lifecycle.t.sol#L137) | The full incident: a partial hold is in place, the desk pauses (a transfer reverts `EnforcedPause`), the custodian relocates the position inside the lockup, supply is unchanged, the hold travels, and the lost wallet is unverified. After unpausing and the lockup, only the unfrozen part moves and one more wei reverts `InsufficientUnfrozenBalance` |
| [`test_scenario_retiredWalletCannotBeUsedAgain`](../../test/scenario/Lifecycle.t.sol#L189) | After recovery, a transfer to the retired wallet reverts `RecipientNotVerified` |

The first is the scenario the instrument exists to survive, and every exemption in the system converges on it. Recovery must work **while paused** (the halt is the response to this very incident) and **while the lockup is still running** (a compromise does not wait for a holding period). The freeze must travel rather than being dropped, or recovery would launder an operational hold. Supply must be unchanged, or recovery would be issuance.

The second closes the loop on eviction: `forcedRecovery` calls `removeIdentity`, so the lost wallet fails the identity gate from that point on, unless compliance deliberately registers it again. Without it, a compromised key could keep receiving transfers from counterparties who do not know it is compromised. Whether the retired wallet can still collect income is covered in [`test_recoveredLostWallet_cannotClaim`](../../test/scenario/EdgeCases.t.sol#L183).

---

## 3. Sanction

| Test | Asserts |
| :--- | :------ |
| [`test_scenario_withdrawnIdentitySuspendsPosition`](../../test/scenario/Lifecycle.t.sol#L218) | A holder whose identity is withdrawn cannot sell (`SenderNotVerified`) or be topped up (`RecipientNotVerified`), the balance is unchanged, and the issuer can still burn it |
| [`test_scenario_reverificationReleasesPosition`](../../test/scenario/Lifecycle.t.sol#L250) | Re-registering the holder releases the position and the whole balance transfers |

`removeIdentity` is what compliance reaches for when an investor may no longer hold the instrument at all. The scenario asserts the three properties that make it a **suspension rather than a seizure**: movement stops in both directions, the balance survives, and compliance can undo it. The burn at the end shows the lawful exit remains open.

This is the end-to-end counterpart of the sender-side identity check documented under [the transfer gate](./07-security-token.md#the-transfer-gate-42-43). An expiry that arrives on its own, rather than a removal, is walked in [`test_kycExpiryDuringLockupAndWithUnclaimedIncome`](../../test/scenario/EdgeCases.t.sol#L120).

---

## 4. The holder cap

| Test | Asserts |
| :--- | :------ |
| [`test_scenario_capRefusesNewHolderThenAdmitsReplacement`](../../test/scenario/Lifecycle.t.sol#L275) | With the cap lowered to the two current holders, a third subscriber's mint reverts `ComplianceCheckFailed`; once one holder exits completely (count 1), the same subscriber is admitted (count 2) |
| [`test_scenario_replacementAtCapIsAllowed`](../../test/scenario/Lifecycle.t.sol#L305) | With a cap of 1, a full-balance transfer to a wallet that holds nothing settles and the count stays at 1 |

Together these establish that the cap limits **concurrent holders, not participation over time**. A cap that refused the replacement would freeze a full placement permanently. Both lower the cap from the deployed 499 so it can be reached in a test.

---

## 5. Jurisdiction

| Test | Asserts |
| :--- | :------ |
| [`test_scenario_closingAJurisdictionBlocksInboundOnly`](../../test/scenario/Lifecycle.t.sol#L334) | A transfer into France settles; after France is closed the same transfer reverts `ComplianceCheckFailed`, while the French holder can still send out, leaving both balances where they began |

A distribution restriction governs who the instrument may be **placed with**. Trapping existing holders would be a different measure with different legal meaning: immobilising a specific position is the freeze and recovery machinery's job. Recovering a position into a wallet of the same investor that sits in a blocked jurisdiction is a separate case, in [`test_recovery_intoBlockedJurisdictionWalletOfSameInvestor`](../../test/scenario/EdgeCases.t.sol#L168).

---

## 6. Rules compose, not override

| Test | Asserts |
| :--- | :------ |
| [`test_scenario_everyRuleMustPassIndependently`](../../test/scenario/Lifecycle.t.sol#L376) | A full partial freeze, an unexpired lockup and a closed jurisdiction are stacked on one transfer and lifted one at a time. The freeze step reverts `InsufficientUnfrozenBalance`; the next two revert `ComplianceCheckFailed(from, to, amount)`, and at each of them the test asks every module for its own verdict (lockup and country refuse, then only country refuses, the holder cap allows throughout). The transfer settles only after the last blocker is cleared |

It stacks the three blockers on the same transfer, then removes them in sequence: freeze released (still blocked by the lockup and the country rule), lockup elapsed (still blocked by the country rule), jurisdiction reopened (settles).

The engine reports every modular rejection as the same `ComplianceCheckFailed`, which does not say which module refused: `canTransfer` returns a bool in ERC-3643 and this repository keeps that interface. Asking each module directly is what pins each rejection on the rule the step expects, rather than assuming it. What the sequence shows is that the rules compose as a strict **AND** and that clearing one does not clear the others.
