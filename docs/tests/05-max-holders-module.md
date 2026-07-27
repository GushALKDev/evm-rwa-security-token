# Max Holders Module (Phase 2)

**Suites:** [`MaxHoldersModuleTest`](../../test/unit/MaxHoldersModule.t.sol) (25 unit + 2 fuzz)
**Covers:** roadmap item 2.2 · [Guide 2, holder-count transitions](../02-mathematics.md#5-holder-count-transitions-without-enumeration)

---

> A cap on concurrent holders, which is what a private placement is legally bound by. The count cannot be computed on demand — an ERC-20 has no holder enumeration and iterating one would not fit in a transaction — so it is maintained incrementally in the lifecycle hooks. That makes it a state machine whose correctness is not self-evident, which is why it is fuzzed against reality rather than merely point-tested.

## Constructor

| Test | Asserts |
| :--- | :------ |
| [`test_constructor_setsState`](../../test/unit/MaxHoldersModule.t.sol#L59) | Engine, token, cap and roles are set, and the initial `MaxHoldersUpdated` fires |
| [`test_constructor_revertsOnZeroCap`](../../test/unit/MaxHoldersModule.t.sol#L67) | A zero cap is refused: it would block every mint and make the token unusable |
| [`test_constructor_revertsOnZeroToken`](../../test/unit/MaxHoldersModule.t.sol#L72) | A zero token is refused, since the rule reads balances to detect transitions |

---

## Counting without enumeration

The count changes only on a true transition. Every shape of balance movement has a test, because each is a different branch of the transition logic.

| Test | Asserts |
| :--- | :------ |
| [`test_mint_incrementsCount`](../../test/unit/MaxHoldersModule.t.sol#L81) | A mint to a fresh wallet adds a holder |
| [`test_mint_toExistingHolderDoesNotIncrement`](../../test/unit/MaxHoldersModule.t.sol#L90) | A mint to someone who already holds does not double-count them |
| [`test_transfer_toNewHolderIncrements`](../../test/unit/MaxHoldersModule.t.sol#L97) | A partial transfer to a fresh wallet adds a holder |
| [`test_transfer_betweenExistingHoldersKeepsCountFlat`](../../test/unit/MaxHoldersModule.t.sol#L114) | Moving between two existing holders changes nothing |
| [`test_transfer_senderEmptyingDecrements`](../../test/unit/MaxHoldersModule.t.sol#L123) | A sender emptying out to an existing holder removes one |
| [`test_transfer_fullBalanceKeepsCountFlat`](../../test/unit/MaxHoldersModule.t.sol#L105) | **The replacement case**: one wallet empties while another fills, so the count is unchanged |
| [`test_burn_toZeroDecrements`](../../test/unit/MaxHoldersModule.t.sol#L133) | A burn that empties a wallet removes a holder |
| [`test_burn_partialDoesNotDecrement`](../../test/unit/MaxHoldersModule.t.sol#L140) | A partial burn leaves the holder counted |
| [`test_holderCount_emitsOnChange`](../../test/unit/MaxHoldersModule.t.sol#L147) | `HolderCountUpdated` fires only when the count actually moves, not on every hook |

The hooks run *after* balances settle, which is what makes the transition detectable at all: `balanceOf(to) == amount` means "this wallet came from zero", and `balanceOf(from) == 0` means "this wallet just left". Reading pre-transfer balances would require the module to reconstruct the delta itself.

The replacement case is the one a naive implementation gets wrong. Handling "recipient joined" and "sender left" as independent increments and decrements happens to give the right answer here, but only if both are evaluated against post-transfer state; evaluated against pre-transfer state, the same transfer both adds and fails to remove, and the count drifts up by one on every full-balance transfer.

---

## Enforcement

| Test | Asserts |
| :--- | :------ |
| [`test_moduleCheck_allowsBelowCap`](../../test/unit/MaxHoldersModule.t.sol#L161) | Below the cap, a new holder is admitted |
| [`test_moduleCheck_blocksNewHolderAtCap`](../../test/unit/MaxHoldersModule.t.sol#L168) | At the cap, a new holder is refused |
| [`test_moduleCheck_allowsExistingHolderAtCap`](../../test/unit/MaxHoldersModule.t.sol#L179) | At the cap, an existing holder may still receive more: the cap counts holders, not transfers |
| [`test_moduleCheck_allowsReplacementAtCap`](../../test/unit/MaxHoldersModule.t.sol#L192) | **At the cap, a replacement is allowed**: if the sender empties in the same transfer, one holder swaps for another and the count never exceeds the cap |
| [`test_moduleCheck_allowsBurn`](../../test/unit/MaxHoldersModule.t.sol#L205) | A burn is always allowed, since it can only reduce the count |

Allowing the replacement is the difference between a cap that limits **concurrent holders** and one that limits participation over time. Refusing it would mean a full placement is frozen: no new investor can ever enter, even as others exit completely, because every candidate is evaluated as "one more holder" without regard to the seat being vacated in the same movement. The scenario suite walks this end to end in [`test_scenario_replacementAtCapIsAllowed`](../../test/scenario/Lifecycle.t.sol#L305).

---

## Hook access

| Test | Asserts |
| :--- | :------ |
| [`test_moduleCreated_revertsForNonCompliance`](../../test/unit/MaxHoldersModule.t.sol#L217) | Only the bound engine may drive `moduleCreated` |
| [`test_moduleTransferred_revertsForNonCompliance`](../../test/unit/MaxHoldersModule.t.sol#L223) | Only the bound engine may drive `moduleTransferred` |
| [`test_moduleDestroyed_revertsForNonCompliance`](../../test/unit/MaxHoldersModule.t.sol#L229) | Only the bound engine may drive `moduleDestroyed` |

An ungated hook here is a direct attack on the cap: anyone could call `moduleDestroyed` repeatedly to drive the count to zero, and then the placement admits unlimited holders while the module still reports itself as enforcing a limit.

---

## Rule admin

| Test | Asserts |
| :--- | :------ |
| [`test_setMaxHolders_updatesAndEmits`](../../test/unit/MaxHoldersModule.t.sol#L239) | The agent raises or lowers the cap and `MaxHoldersUpdated` fires |
| [`test_setMaxHolders_revertsForNonAgent`](../../test/unit/MaxHoldersModule.t.sol#L250) | The cap is agent-gated |
| [`test_setMaxHolders_revertsOnZero`](../../test/unit/MaxHoldersModule.t.sol#L258) | A zero cap is refused after construction too |
| [`test_setMaxHolders_revertsBelowCurrentCount`](../../test/unit/MaxHoldersModule.t.sol#L266) | **The cap cannot be set below the live count**, which would put the system in a state its own rule says is illegal |
| [`test_setMaxHolders_allowsEqualToCurrentCount`](../../test/unit/MaxHoldersModule.t.sol#L275) | Setting it exactly at the current count is allowed: the placement is simply full |

Refusing a cap below the current count keeps the invariant `holderCount <= maxHolders` true at all times rather than only after transfers. Allowing it would create a state that no transfer caused and no transfer can repair — existing holders cannot be evicted by a rule module — so the system would sit permanently in violation of its own constraint.

---

## Fuzz

| Test | Property |
| :--- | :------- |
| [`testFuzz_countMatchesReality`](../../test/unit/MaxHoldersModule.t.sol#L290) | After an arbitrary sequence of holder movements, the module's count equals the number of addresses actually holding a positive balance |
| [`testFuzz_countNeverExceedsCap`](../../test/unit/MaxHoldersModule.t.sol#L311) | Across arbitrary admission attempts, the count never exceeds the cap |

The first is the test that justifies the whole incremental design. The count is a cached derivative of state the module never enumerates, so the only meaningful assurance is to compare it against the enumeration the contract cannot afford — which a test *can* afford. It is the closest thing in this suite to a stateful invariant, and it is why the pending handler suite ([Gaps](./11-gaps-and-roadmap.md)) is a smaller gap here than for the token.
