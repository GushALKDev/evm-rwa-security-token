# Max Holders Module (Phase 2)

**Suites:** [`MaxHoldersModuleTest`](../../test/unit/MaxHoldersModule.t.sol) (29 unit + 2 fuzz)
**Covers:** roadmap item 2.2 · [Guide 2, holder-count transitions](../02-mathematics.md#5-holder-count-transitions-without-enumeration)

---

> A cap on concurrent holders, which is what a private placement is legally bound by. The count cannot be computed on demand (an ERC-20 has no holder enumeration and iterating one would not fit in a transaction), so it is maintained incrementally in the lifecycle hooks. That makes it a state machine whose correctness is not self-evident, which is why it is fuzzed against a recount rather than only point-tested.

The unit tests use a cap of 3 and drive the hooks from a plain address standing in for the engine, against [`MockToken`](../../test/helpers/MockToken.sol), moving the balance before firing the hook as the real token does.

## Constructor

| Test | Asserts |
| :--- | :------ |
| [`test_constructor_setsState`](../../test/unit/MaxHoldersModule.t.sol#L89) | Engine, token, cap and name are set, and the count starts at zero |
| [`test_constructor_revertsOnZeroCap`](../../test/unit/MaxHoldersModule.t.sol#L97) | A zero cap reverts `MaxHoldersZero`: it would block every mint and make the token unusable |
| [`test_constructor_revertsOnZeroToken`](../../test/unit/MaxHoldersModule.t.sol#L102) | A zero token reverts `ZeroAddress`, since the rule reads balances to detect transitions |

---

## Attachment

| Test | Asserts |
| :--- | :------ |
| [`test_attachment_statefulAndSupplyGated`](../../test/unit/MaxHoldersModule.t.sol#L61) | The module is not plug and play and reads the token it was built for; `canComplianceBind` is true for its engine and false for another, false while the token has supply, and false again after a bind and an unbind |

A count attached to a token that already has holders would start at zero and make the first exit underflow; attached twice, it would miss the movements made while it was out. Both are refused at `addModule` (review finding 6). The deployed-wiring counterpart is [`test_addModule_rejectsMaxHoldersOnceSupplyExists`](../../test/scenario/Regressions.t.sol#L381).

---

## Counting without enumeration

The count changes only on a true transition. Every shape of balance movement has a test, because each is a different branch of the transition logic.

| Test | Asserts |
| :--- | :------ |
| [`test_mint_incrementsCount`](../../test/unit/MaxHoldersModule.t.sol#L111) | Mints to two fresh wallets take the count to 1, then 2 |
| [`test_mint_toExistingHolderDoesNotIncrement`](../../test/unit/MaxHoldersModule.t.sol#L120) | A second mint to the same wallet leaves the count at 1 |
| [`test_transfer_toNewHolderIncrements`](../../test/unit/MaxHoldersModule.t.sol#L127) | A partial transfer to a fresh wallet adds a holder |
| [`test_transfer_betweenExistingHoldersKeepsCountFlat`](../../test/unit/MaxHoldersModule.t.sol#L144) | Moving part of a balance between two existing holders leaves the count at 2 |
| [`test_transfer_fullBalanceKeepsCountFlat`](../../test/unit/MaxHoldersModule.t.sol#L135) | **The replacement case**: one wallet empties while another fills, so the count stays at 1 |
| [`test_transfer_selfTransferKeepsCountFlat`](../../test/unit/MaxHoldersModule.t.sol#L163) | **A self-transfer of the full balance changes nothing**: the balance and the count are unchanged. Regression test for the bug the invariant suite found, see below |
| [`test_transfer_partialSelfTransferKeepsCountFlat`](../../test/unit/MaxHoldersModule.t.sol#L173) | The same for a partial self-transfer, which trips a different branch of the inference |
| [`test_transfer_senderEmptyingDecrements`](../../test/unit/MaxHoldersModule.t.sol#L181) | A sender emptying out to an existing holder takes the count from 2 to 1 |
| [`test_burn_toZeroDecrements`](../../test/unit/MaxHoldersModule.t.sol#L191) | A burn that empties a wallet takes the count to 0 |
| [`test_burn_partialDoesNotDecrement`](../../test/unit/MaxHoldersModule.t.sol#L198) | A partial burn leaves the holder counted |
| [`test_holderCount_emitsOnChange`](../../test/unit/MaxHoldersModule.t.sol#L205) | `HolderCountUpdated(1)` fires when a mint admits the first holder |

The hooks run *after* balances settle, which is what makes the transition detectable at all: `balanceOf(to) == amount` means "this wallet came from zero", and `balanceOf(from) == 0` means "this wallet just left". Reading pre-transfer balances would require the module to reconstruct the delta itself.

**The self-transfer case was a live bug**, found by the [invariant suite](./11-invariants.md#the-bug-it-found) and not by any unit or scenario test. With `from == to` and a full-balance send, `balanceOf(to) == amount` reads as "the recipient came from zero" while the sender is plainly not empty, so the two signals fail to cancel and the count rises for a holder who never appeared. Anyone could repeat it for free until the count reached the cap. The hook now discards `from == to` before the inference runs.

**Zero amounts were a second live bug** (review finding 1). The same inference reads `balanceOf(from) == 0` as "the sender left", which is also true for a sender that held nothing before. A zero-amount `transferFrom` from an empty verified wallet needs no allowance, so any address could drain the count, admit holders past the cap, and then make legitimate exits revert on underflow. Every stateful hook now returns early on a zero amount. The tests for it run against the deployed wiring and are under [finding 1](./14-regressions.md#1-zero-amounts-deflated-the-holder-count); the fuzz test below also draws zero amounts.

---

## Enforcement

| Test | Asserts |
| :--- | :------ |
| [`test_moduleCheck_allowsBelowCap`](../../test/unit/MaxHoldersModule.t.sol#L219) | Below the cap, a mint to a new holder is allowed |
| [`test_moduleCheck_blocksNewHolderAtCap`](../../test/unit/MaxHoldersModule.t.sol#L226) | At the cap, both a mint and a partial transfer to a new holder are refused |
| [`test_moduleCheck_allowsExistingHolderAtCap`](../../test/unit/MaxHoldersModule.t.sol#L237) | At the cap, an existing holder may still receive more: the cap counts holders, not transfers |
| [`test_moduleCheck_allowsReplacementAtCap`](../../test/unit/MaxHoldersModule.t.sol#L250) | **At the cap, a replacement is allowed**: a full-balance transfer to a new holder passes the check and the count stays at the cap |
| [`test_moduleCheck_allowsBurn`](../../test/unit/MaxHoldersModule.t.sol#L263) | A burn is always allowed, since it can only reduce the count |
| [`test_moduleCheck_zeroAmountPassesAtFullCap`](../../test/unit/MaxHoldersModule.t.sol#L80) | At a full cap, one wei to a new holder is refused while a zero-amount transfer and a zero-amount mint to the same address are allowed: a zero amount adds no holder (review finding 12) |

Allowing the replacement is the difference between a cap that limits **concurrent holders** and one that limits participation over time. Refusing it would mean a full placement is frozen: no new investor can ever enter, even as others exit completely. The scenario suite walks this end to end in [`test_scenario_replacementAtCapIsAllowed`](../../test/scenario/Lifecycle.t.sol#L305).

---

## Hook access

| Test | Asserts |
| :--- | :------ |
| [`test_moduleCreated_revertsForNonCompliance`](../../test/unit/MaxHoldersModule.t.sol#L275) | Only the bound engine may drive `moduleCreated` (`OnlyCompliance(caller, engine)`) |
| [`test_moduleTransferred_revertsForNonCompliance`](../../test/unit/MaxHoldersModule.t.sol#L281) | Only the bound engine may drive `moduleTransferred` |
| [`test_moduleDestroyed_revertsForNonCompliance`](../../test/unit/MaxHoldersModule.t.sol#L287) | Only the bound engine may drive `moduleDestroyed` |

An ungated hook here is a direct attack on the cap: anyone could call `moduleDestroyed` repeatedly to drive the count to zero, and then the placement admits unlimited holders while the module still reports itself as enforcing a limit.

---

## Rule admin

| Test | Asserts |
| :--- | :------ |
| [`test_setMaxHolders_updatesAndEmits`](../../test/unit/MaxHoldersModule.t.sol#L297) | The agent sets the cap to 10 and `MaxHoldersUpdated(10)` fires |
| [`test_setMaxHolders_revertsForNonAgent`](../../test/unit/MaxHoldersModule.t.sol#L308) | The cap is agent-gated |
| [`test_setMaxHolders_revertsOnZero`](../../test/unit/MaxHoldersModule.t.sol#L316) | A zero cap reverts `MaxHoldersZero` after construction too |
| [`test_setMaxHolders_revertsBelowCurrentCount`](../../test/unit/MaxHoldersModule.t.sol#L324) | **The cap cannot be set below the live count**: with two holders, a cap of 1 reverts `MaxHoldersBelowCurrentCount(1, 2)` |
| [`test_setMaxHolders_allowsEqualToCurrentCount`](../../test/unit/MaxHoldersModule.t.sol#L333) | Setting it exactly at the current count is allowed: the placement is simply full |

Refusing a cap below the current count keeps `holderCount <= maxHolders` true at all times rather than only after transfers. Allowing it would create a state that no transfer caused and no transfer can repair (existing holders cannot be evicted by a rule module). What a full placement does next (exits, re-entries, replacements at the lowered cap) is walked in [`test_holderCap_loweredToCount_thenExitsAndEntries`](../../test/scenario/EdgeCases.t.sol#L70).

---

## Fuzz

| Test | Asserts |
| :--- | :------ |
| [`testFuzz_countMatchesReality`](../../test/unit/MaxHoldersModule.t.sol#L351) | Over up to 40 random mints, transfers and burns across five wallets, with amounts drawn by mode (zero, full balance, one wei, any), the count equals a recount of the wallets holding a positive balance **after every step** |
| [`testFuzz_countNeverExceedsCap`](../../test/unit/MaxHoldersModule.t.sol#L386) | Over up to 30 mint attempts to fresh wallets, each gated by `moduleCheck`, the count never exceeds the cap |

The first is the test that justifies the incremental design. The count is a cached derivative of state the module never enumerates, so the meaningful check is to compare it against the enumeration the contract cannot afford, which a test *can* afford. Drawing amounts by mode puts self-transfers, zero amounts and full exits into most runs rather than leaving them to chance. The same property across the whole system, with freeze, pause, recovery and identity withdrawal interleaved, is [`invariant_holderCountMatchesReality`](../../test/invariant/Invariants.t.sol#L166).
