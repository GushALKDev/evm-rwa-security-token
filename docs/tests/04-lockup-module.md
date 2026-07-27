# Lockup Module (Phase 2)

**Suites:** [`LockupModuleTest`](../../test/unit/LockupModule.t.sol) (26 unit + 2 fuzz)
**Covers:** roadmap item 2.4 · [Guide 2, the lockup clock](../02-mathematics.md#6-the-lockup-clock) · [Guide 4, lockup model choice](../04-tradeoffs.md)

---

> A holding period, enforced from the moment a wallet acquires a position. The rule is a small state machine — a clock that starts when a wallet goes from zero and clears when it returns to zero — and almost every test here exists because of a specific way that machine can be made to misbehave. The defining one is the griefing guard: under a naive design, anyone can send a holder one wei and restart their lockup forever.

## Constructor

| Test | Asserts |
| :--- | :------ |
| [`test_constructor_setsState`](../../test/unit/LockupModule.t.sol#L60) | Engine, token, period and roles are all set, and the module reports its name |
| [`test_constructor_revertsOnZeroToken`](../../test/unit/LockupModule.t.sol#L69) | A zero token is refused: the rule reads balances, so it is useless without one |
| [`test_constructor_revertsOnZeroCompliance`](../../test/unit/LockupModule.t.sol#L74) | A zero engine reverts through the `AbstractComplianceModule` binding |

---

## The clock starts on acquisition

| Test | Asserts |
| :--- | :------ |
| [`test_mint_startsClock`](../../test/unit/LockupModule.t.sol#L84) | Primary issuance starts the clock: a subscription is the archetypal acquisition |
| [`test_transfer_startsClockForNewHolder`](../../test/unit/LockupModule.t.sol#L100) | A wallet receiving from zero starts its own clock, so a buyer inherits a fresh lockup |
| [`test_lockStart_isZeroForUnknownInvestor`](../../test/unit/LockupModule.t.sol#L110) | A wallet that never held reads back a zero clock |

The clock is a property of the **acquisition**, not of the wallet or of the tokens. This is what stops a position being freed by passing it through a third party: the recipient's clock starts on receipt, so the holding period restarts rather than being inherited from the sender. Exercised end to end in [`test_scenario_lockupFollowsTheAcquisition`](../../test/scenario/Lifecycle.t.sol#L110).

---

## Enforcement, and the boundary to the second

| Test | Asserts |
| :--- | :------ |
| [`test_moduleCheck_blocksBeforeExpiry`](../../test/unit/LockupModule.t.sol#L119) | A position inside its holding period cannot be disposed of |
| [`test_moduleCheck_blocksOneSecondBeforeExpiry`](../../test/unit/LockupModule.t.sol#L125) | One second before, still blocked |
| [`test_moduleCheck_allowsExactlyAtExpiry`](../../test/unit/LockupModule.t.sol#L133) | **Exactly at expiry, allowed**: the comparison is `>=`, so the period is inclusive of its final instant |
| [`test_moduleCheck_allowsAfterExpiry`](../../test/unit/LockupModule.t.sol#L140) | After expiry, allowed |
| [`test_moduleCheck_allowsMint`](../../test/unit/LockupModule.t.sol#L148) | A mint is an acquisition, not a disposal, so the rule never blocks issuance |
| [`test_moduleCheck_allowsSenderWithNoClock`](../../test/unit/LockupModule.t.sol#L153) | A sender with no clock is unrestrained: the rule restrains positions it started, not addresses in general |

Three point tests around a single boundary look redundant until you consider what each catches. `blocksOneSecondBefore` and `allowsExactlyAtExpiry` are adjacent instants: an off-by-one in either direction flips exactly one of them. The fuzz test below covers the space; these two pin the edge, which fuzzing reaches only by luck.

---

## The griefing guard

| Test | Asserts |
| :--- | :------ |
| [`test_griefing_oneWeiCannotRelockPosition`](../../test/unit/LockupModule.t.sol#L166) | **The reason the clock is not reset on receipt.** A holder near the end of their period receives one wei from a hostile party; their clock does not move, and they are released on schedule |
| [`test_subsequentReceiptDoesNotResetClock`](../../test/unit/LockupModule.t.sol#L185) | The same property for an ordinary, non-hostile top-up: receiving more of an existing position never extends the lockup |

Under a "reset the clock on every incoming transfer" design, the lockup becomes a weapon: any address can send a holder one wei immediately before their period expires and restart it, indefinitely and for negligible cost. The holder can never sell. Starting the clock only on the `0 → positive` transition removes the lever entirely — there is nothing an outsider can do to a wallet that already holds a balance.

The cost of this choice is stated plainly in [Guide 4](../04-tradeoffs.md): it is a *per-wallet* lockup, not a per-acquisition one, so a holder who tops up does not lock the new tokens separately. A strict per-lot lockup needs partitions, which are out of scope. The griefing immunity was judged worth more than the precision.

---

## Clock clearing

| Test | Asserts |
| :--- | :------ |
| [`test_exitToZero_clearsClockAndRelocksOnReentry`](../../test/unit/LockupModule.t.sol#L204) | Fully exiting clears the clock, and re-entering later starts a fresh period |
| [`test_partialTransfer_doesNotClearClock`](../../test/unit/LockupModule.t.sol#L226) | Selling part of a position leaves the clock running on the remainder |
| [`test_burnToZero_clearsClock`](../../test/unit/LockupModule.t.sol#L236) | A burn that empties a wallet clears the clock, like a transfer out |
| [`test_partialBurn_doesNotClearClock`](../../test/unit/LockupModule.t.sol#L243) | A partial burn leaves it running |

The pairing is the point. If a partial exit cleared the clock, a holder could sell one wei to reset their own lockup — the mirror image of the griefing vector, exploitable by the holder instead of against them. Clearing only on a true `positive → 0` transition closes both directions with one rule.

---

## Hook access

| Test | Asserts |
| :--- | :------ |
| [`test_moduleTransferred_revertsForNonCompliance`](../../test/unit/LockupModule.t.sol#L258) | Only the bound engine may drive `moduleTransferred` |
| [`test_moduleCreated_revertsForNonCompliance`](../../test/unit/LockupModule.t.sol#L264) | Only the bound engine may drive `moduleCreated` |
| [`test_moduleDestroyed_revertsForNonCompliance`](../../test/unit/LockupModule.t.sol#L270) | Only the bound engine may drive `moduleDestroyed` |
| [`test_hooks_revertForIssuer`](../../test/unit/LockupModule.t.sol#L277) | Even the issuer cannot drive the hooks directly: this is a machine-to-machine gate, not a privilege level |

The clock is only trustworthy if the sole thing that can move it is a real balance change. An ungated hook would let anyone start or clear a clock at will, which is a more direct attack than the one-wei griefing the design already defends against.

---

## Rule admin

| Test | Asserts |
| :--- | :------ |
| [`test_setLockupPeriod_updatesAndEmits`](../../test/unit/LockupModule.t.sol#L287) | The agent updates the period and `LockupPeriodUpdated` fires |
| [`test_setLockupPeriod_revertsForNonAgent`](../../test/unit/LockupModule.t.sol#L298) | The period is agent-gated |
| [`test_zeroPeriod_disablesRule`](../../test/unit/LockupModule.t.sol#L307) | A zero period disables the rule without removing the module |
| [`test_shorteningPeriod_releasesExistingHolderEarly`](../../test/unit/LockupModule.t.sol#L317) | **Period changes apply retroactively**: shortening the period releases holders whose stored clock now satisfies it |

The retroactive behaviour is a consequence of storing the clock *start* rather than a computed release date: the check is always `now >= start + period` against the current period. That makes shortening an immediate release and lengthening an immediate extension for existing holders. The test pins it so the semantics are a documented decision rather than an accident of the storage layout.

---

## Fuzz

| Test | Property |
| :--- | :------- |
| [`testFuzz_moduleCheck_tracksBoundary`](../../test/unit/LockupModule.t.sol#L334) | For any period and any elapsed time, the verdict is exactly `elapsed >= period` |
| [`testFuzz_incomingTransferNeverResetsClock`](../../test/unit/LockupModule.t.sol#L349) | For any dust amount and any delay, an incoming transfer leaves the clock untouched |

The second is the griefing guard stated as a property rather than a scenario: not "one wei at this moment does not relock", but "no amount at any time can move the clock of a wallet that already holds a balance".
