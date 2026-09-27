# Lockup Module (Phase 2)

**Suites:** [`LockupModuleTest`](../../test/unit/LockupModule.t.sol) (31 unit + 2 fuzz)
**Covers:** roadmap item 2.4 · [Guide 2, the lockup clock](../02-mathematics.md#6-the-lockup-clock) · [Guide 4, lockup model choice](../04-tradeoffs.md)

---

> A holding period, enforced from the moment a wallet acquires a position. The rule is a small state machine (a clock that starts when a wallet goes from zero and clears when it returns to zero) and almost every test here exists because of a specific way that machine can be made to misbehave. The defining one is the griefing guard: under a naive design, anyone can send a holder one wei and restart their lockup forever.

The unit tests drive the hooks from a plain address standing in for the engine, against [`MockToken`](../../test/helpers/MockToken.sol): each helper moves the balance first and then fires the hook, the order the real token uses.

## Constructor

| Test | Asserts |
| :--- | :------ |
| [`test_constructor_setsState`](../../test/unit/LockupModule.t.sol#L87) | Engine, token, period, name and both roles are set |
| [`test_constructor_revertsOnZeroToken`](../../test/unit/LockupModule.t.sol#L96) | A zero token reverts `ZeroAddress`: the rule reads balances, so it is useless without one |
| [`test_constructor_revertsOnZeroCompliance`](../../test/unit/LockupModule.t.sol#L101) | A zero engine reverts with the `OnlyCompliance` selector raised by the `AbstractComplianceModule` constructor |

---

## Attachment

| Test | Asserts |
| :--- | :------ |
| [`test_attachment_statefulAndSupplyGated`](../../test/unit/LockupModule.t.sol#L62) | The module is not plug and play and reads the token it was built for; `canComplianceBind` is true for its engine and false for another, false while the token has supply, and false again after a bind and an unbind |

A clock can only be right if the module saw the acquisition that started it. Attaching the lockup to a token that already has holders would leave them with no clock, and so unrestricted; attaching it a second time would miss everything that moved while it was out. Both are refused at `addModule` (review finding 6). The deployed-wiring counterpart is [`test_addModule_rejectsLockupOnceSupplyExists`](../../test/scenario/Regressions.t.sol#L387).

---

## The clock starts on acquisition

| Test | Asserts |
| :--- | :------ |
| [`test_mint_startsClock`](../../test/unit/LockupModule.t.sol#L111) | Primary issuance starts the clock: `LockupStarted` fires with the start and unlock time, and `lockStart` and `unlocksAt` read them back |
| [`test_transfer_startsClockForNewHolder`](../../test/unit/LockupModule.t.sol#L127) | A wallet receiving from zero starts its own clock at the time of receipt |
| [`test_lockStart_isZeroForUnknownInvestor`](../../test/unit/LockupModule.t.sol#L137) | A wallet that never held reads back a zero start and a zero unlock time |

The clock is a property of the **acquisition**, not of the wallet or of the tokens. This is what stops a position being freed by passing it through a third party: the recipient's clock starts on receipt, so the holding period restarts rather than being inherited from the sender. Exercised end to end in [`test_scenario_lockupFollowsTheAcquisition`](../../test/scenario/Lifecycle.t.sol#L110).

---

## Enforcement, and the boundary to the second

| Test | Asserts |
| :--- | :------ |
| [`test_moduleCheck_blocksBeforeExpiry`](../../test/unit/LockupModule.t.sol#L146) | A position inside its holding period cannot be disposed of |
| [`test_moduleCheck_blocksOneSecondBeforeExpiry`](../../test/unit/LockupModule.t.sol#L152) | One second before, still blocked |
| [`test_moduleCheck_allowsExactlyAtExpiry`](../../test/unit/LockupModule.t.sol#L160) | **Exactly at expiry, allowed**: the comparison is `>=`, so the period is inclusive of its final instant |
| [`test_moduleCheck_allowsAfterExpiry`](../../test/unit/LockupModule.t.sol#L167) | After expiry, allowed |
| [`test_moduleCheck_allowsMint`](../../test/unit/LockupModule.t.sol#L175) | A mint (sender zero) is an acquisition, not a disposal, so the rule never blocks issuance |
| [`test_moduleCheck_allowsSenderWithNoClock`](../../test/unit/LockupModule.t.sol#L180) | A sender with no clock is unrestrained: the rule restrains positions it started, not addresses in general |
| [`test_moduleCheck_zeroAmountPassesDuringLockup`](../../test/unit/LockupModule.t.sol#L81) | For a sender inside the lockup, one wei is refused and a zero amount is allowed: a zero amount disposes of nothing |

Three point tests around a single boundary look redundant until you consider what each catches. `blocksOneSecondBeforeExpiry` and `allowsExactlyAtExpiry` are adjacent instants: an off-by-one in either direction flips exactly one of them. The fuzz test below covers the space; these two pin the edge, which fuzzing reaches only by luck.

The zero-amount case is review finding 12: the hooks already ignored zero amounts after finding 1, but the check still refused one from a sender in lockup although nothing was disposed of. Every module's check now lets a zero amount through; the token still applies its own identity and freeze checks to it, see [`test_zeroAmountTransferFrom_passesModulesButNotTheGate`](../../test/scenario/Regressions.t.sol#L641).

---

## The griefing guard

| Test | Asserts |
| :--- | :------ |
| [`test_griefing_oneWeiCannotRelockPosition`](../../test/unit/LockupModule.t.sol#L193) | **The reason the clock is not reset on receipt.** One second before a holder's unlock, a hostile party sends one wei; `lockStart` and `unlocksAt` do not move, and the holder is released at the original unlock time |
| [`test_subsequentReceiptDoesNotResetClock`](../../test/unit/LockupModule.t.sol#L213) | The same for an ordinary top-up 180 days in: the start is unchanged and the holder is released on the original schedule |

Under a "reset the clock on every incoming transfer" design, the lockup becomes a weapon: any address can send a holder one wei immediately before their period expires and restart it, indefinitely and for negligible cost. Starting the clock only on the `0 → positive` transition removes the lever: an outsider cannot move the clock of a wallet that already holds a balance.

The cost of this choice is stated plainly in [Guide 4](../04-tradeoffs.md): it is a *per-wallet* lockup, not a per-acquisition one, so a holder who tops up does not lock the new tokens separately. A strict per-lot lockup needs partitions, which are out of scope.

---

## Forced recovery

The token's recovery path fires the ordinary transfer hook, which the module used to read as a fresh acquisition: review finding 4, forced recovery restarted the lockup. The module now asks the token `recovering()` and moves the start instead. These tests set that flag on the mock around the hook call.

| Test | Asserts |
| :--- | :------ |
| [`test_recovery_carriesClockToEmptyWallet`](../../test/unit/LockupModule.t.sol#L244) | Recovered 100 days in, into an empty wallet: the destination takes the lost wallet's original start, and the lost wallet's clock is cleared |
| [`test_recovery_keepsDestinationsEarlierStart`](../../test/unit/LockupModule.t.sol#L256) | Recovered into a wallet whose own clock started earlier: the destination keeps its earlier start, and the lost wallet's clock is cleared |
| [`test_recovery_withoutClockOnLostWallet_changesNothing`](../../test/unit/LockupModule.t.sol#L270) | A lost wallet with no clock (balance minted without the hook) carries nothing, and neither wallet ends with a clock |

The end-to-end versions, through the real `forcedRecovery`, are under [finding 4](./14-regressions.md#4-forced-recovery-restarted-the-lockup), and the property is a stateful invariant, [`invariant_recoveryKeepsLockupStart`](../../test/invariant/Invariants.t.sol#L205).

---

## Clock clearing

| Test | Asserts |
| :--- | :------ |
| [`test_exitToZero_clearsClockAndRelocksOnReentry`](../../test/unit/LockupModule.t.sol#L284) | Fully exiting emits `LockupCleared` and clears the clock; re-entering later starts a fresh clock at the new time and is blocked again |
| [`test_partialTransfer_doesNotClearClock`](../../test/unit/LockupModule.t.sol#L306) | Selling half a position leaves the clock unchanged |
| [`test_burnToZero_clearsClock`](../../test/unit/LockupModule.t.sol#L316) | A burn that empties a wallet clears the clock, like a transfer out |
| [`test_partialBurn_doesNotClearClock`](../../test/unit/LockupModule.t.sol#L323) | A partial burn leaves it unchanged |

The pairing is the point. If a partial exit cleared the clock, a holder could sell one wei to reset their own lockup: the mirror image of the griefing vector, exploitable by the holder instead of against them. Clearing only on a true `positive → 0` transition closes both directions with one rule.

---

## Hook access

| Test | Asserts |
| :--- | :------ |
| [`test_moduleTransferred_revertsForNonCompliance`](../../test/unit/LockupModule.t.sol#L338) | Only the bound engine may drive `moduleTransferred` (`OnlyCompliance(caller, engine)`) |
| [`test_moduleCreated_revertsForNonCompliance`](../../test/unit/LockupModule.t.sol#L344) | Only the bound engine may drive `moduleCreated` |
| [`test_moduleDestroyed_revertsForNonCompliance`](../../test/unit/LockupModule.t.sol#L350) | Only the bound engine may drive `moduleDestroyed` |
| [`test_hooks_revertForIssuer`](../../test/unit/LockupModule.t.sol#L357) | Even the issuer cannot drive `moduleCreated` directly: this is a machine-to-machine gate, not a privilege level |

The clock is only trustworthy if the sole thing that can move it is a real balance change. An ungated hook would let anyone start or clear a clock at will, which is a more direct attack than the one-wei griefing the design already defends against.

---

## Rule admin

| Test | Asserts |
| :--- | :------ |
| [`test_setLockupPeriod_updatesAndEmits`](../../test/unit/LockupModule.t.sol#L367) | The agent updates the period and `LockupPeriodUpdated` fires |
| [`test_setLockupPeriod_revertsForNonAgent`](../../test/unit/LockupModule.t.sol#L378) | The period is agent-gated (`AccessControlUnauthorizedAccount` with `AGENT_ROLE`) |
| [`test_zeroPeriod_disablesRule`](../../test/unit/LockupModule.t.sol#L387) | With a zero period, a holder minted that same second may dispose of the position: the rule is disabled without removing the module |
| [`test_shorteningPeriod_releasesExistingHolderEarly`](../../test/unit/LockupModule.t.sol#L397) | **Period changes apply retroactively**: a holder blocked under the 365-day period is released 30 days in when the period is shortened to 30 days |

The retroactive behaviour is a consequence of storing the clock *start* rather than a computed release date: the check is always `now >= start + period` against the current period. That makes shortening an immediate release and lengthening an immediate extension for existing holders. The scenario form, in both directions, is [`test_setLockupPeriod_appliesRetroactively`](../../test/scenario/EdgeCases.t.sol#L102).

---

## Fuzz

| Test | Asserts |
| :--- | :------ |
| [`testFuzz_moduleCheck_tracksBoundary`](../../test/unit/LockupModule.t.sol#L414) | For any period up to ten years and any elapsed time up to twenty, the verdict is exactly `elapsed >= period` |
| [`testFuzz_incomingTransferNeverResetsClock`](../../test/unit/LockupModule.t.sol#L429) | For any incoming amount up to the holder's balance and any delay up to ten years, an incoming transfer leaves the clock unchanged |

The second is the griefing guard stated as a property rather than a scenario: not "one wei at this moment does not relock", but "no amount at any time in the fuzzed range moves the clock of a wallet that already holds a balance".
