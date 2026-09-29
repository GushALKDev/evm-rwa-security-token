# Guide 8: Review Notes

**Version:** 1.0
**Prerequisites:** [Guide 7: Security](./07-security.md)
**Next:** [Testing Documentation](./tests/README.md)

---

The code was reviewed in three rounds after the build. Round 1 checked the documentation against the code and measured what the README claimed; round 2 fixed the bugs it found; round 3 covered standards conformance, edge cases and griefing. The entries below are grouped by what each one can show: bugs in the reviewed code, one defect introduced and fixed during the review, and hardening and documentation changes.

## Bugs in the reviewed code

Each of these 13 bugs was reproduced first and has a regression test that failed against the unfixed code; most of those tests run against the deployed wiring in [`test/scenario/Regressions.t.sol`](../test/scenario/Regressions.t.sol). Bugs 1 to 11 were found in round 1 and fixed in round 2; bug 12 was found and fixed in round 3; bug 13 was found and fixed in round 2 and finished in round 3. For bugs 1 to 12, reintroducing the bug into the fixed code makes at least one test fail; bug 13 is in the deployment script and was not checked that way.

**1. Zero amounts deflated the holder count** (`22e214f`)
- Wrong: a zero-amount transfer from a verified wallet holding nothing lowered `MaxHoldersModule.holderCount`. `transferFrom(emptyWallet, x, 0)` needs no allowance, so any address could drain the count, admit holders past the cap, and then make legitimate exits revert on underflow. `burn(nonHolder, 0)` did the same.
- Root cause: the hook infers "the sender left" from `balanceOf(from) == 0` after the move, which is also true for a sender that held nothing before.
- Fix: every stateful hook returns early on a zero amount. Zero-amount transfers stay valid ERC-20 calls.
- Tests: `test_zeroAmountTransfer_doesNotDeflateHolderCount`, `test_zeroAmountTransferFromByStranger_doesNotDeflateHolderCount`, `test_zeroBurnFromNonHolder_doesNotDeflateHolderCount`, `test_zeroAmountSends_doNotBlockLaterExits`.

**2. An unsubmitted attestation could undo a removal** (`480b897`)
- Wrong: an attestation issued while an investor was registered, but never submitted, re-registered them after the agent removed them.
- Root cause: only a signed registration advanced the nonce; agent registrations and removals did not.
- Fix: every write to a record advances the nonce.
- Tests: `test_attestationSignedBeforeRemoval_isRejectedAfterIt`, `test_attestationSignedBeforeAgentUpdate_isRejectedAfterIt`.

**3. A suspended wallet could not be recovered** (`4975329`)
- Wrong: after the agent removed a wallet's identity, `forcedRecovery` reverted with `RecoveryAcrossInvestors(0, id)`, so the position stayed stranded until the agent registered the lost wallet again.
- Root cause: `removeIdentity` deleted the whole record, `investorId` included.
- Fix: removal clears the verification and attributes but keeps `investorId`; recovery skips its own removal call when the wallet is already removed.
- Test: `test_forcedRecovery_succeedsAfterAgentRemovedLostWallet`.

**4. Forced recovery restarted the lockup** (`498c4ef`)
- Wrong: recovering a position into an empty wallet locked the investor again for the full period.
- Root cause: the recovery hook is the ordinary transfer hook, which `LockupModule` read as a fresh acquisition.
- Fix: `LockupModule` asks the token `recovering()` and moves the start instead: an empty destination takes the lost wallet's start, a holding destination keeps the earlier of the two.
- Tests: `test_forcedRecovery_keepsAnExpiredLockupExpired`, `test_forcedRecovery_keepsTheOriginalUnlockTime`, `test_forcedRecovery_intoHoldingWallet_keepsTheEarlierStart`.

**5. Frozen and unverified holders could claim income** (`2c8ea7c`)
- Wrong: `DividendDistributor.claim` paid a holder who was fully frozen or no longer verified.
- Root cause: `claim` read neither the token's freeze state nor the identity registry.
- Fix: `claim` reverts with `ClaimantFrozen` or `ClaimantNotVerified` (an expired KYC counts). The entitlement keeps accruing and is released when the block is lifted. A partial freeze does not block a claim.
- Tests: `test_claim_blockedWhileFullyFrozen_releasedAfterUnfreeze`, `test_claim_blockedWhileUnverified_releasedAfterReverification`, `test_claim_blockedAfterKycExpiry`, `test_claim_allowedUnderPartialFreeze`.

**6. Stateful modules could be attached where they could not keep up** (`f9ab7b1`, `a957a53`)
- Wrong: a holder cap added to a token with holders started at zero and made the first exit underflow; a late lockup had no clock for existing holders; a distributor removed and added back overpaid holders who bought while it was out.
- Root cause: `addModule` and `removeModule` reconciled nothing with existing balances.
- Fix: the T-REX `isPlugAndPlay` / `canComplianceBind` shape. The holder cap and the lockup refuse a token with supply, every stateful module refuses a second attach, and a detached distributor refuses deposits. The follow-up commit fixes a defect this fix introduced (see [Introduced and fixed during the review](#introduced-and-fixed-during-the-review)).
- Tests: `test_addModule_rejectsMaxHoldersOnceSupplyExists`, `test_addModule_rejectsLockupOnceSupplyExists`, `test_addModule_rejectsReattachingARemovedStatefulModule`, `test_addModule_rejectsReattachingARemovedDistributor`, `test_distributor_afterRemoval_refusesDepositsAndPaysAccrued`.

**7. A module could read a different token than the engine's** (`3bdb0c8`)
- Wrong: a stateful module built against another token was accepted and then counted that token's balances.
- Root cause: `addModule` checked only that the module named this engine.
- Fix: `addModule` and `bindToken` reject a module whose `token()` differs from the bound token.
- Tests: `test_addModule_rejectsModuleBuiltForAnotherToken`, `test_bindToken_rejectsRegisteredModuleForAnotherToken`.

**8. An over-burn panicked** (`aa6a0fd`)
- Wrong: burning more than the balance of a wallet with frozen tokens reverted with an arithmetic panic.
- Root cause: the frozen-portion arithmetic ran before the ERC-20 balance check.
- Fix: `burn` checks the balance first and reverts with `ERC20InsufficientBalance`.
- Test: `test_burn_aboveBalance_revertsWithInsufficientBalance`.

**9. Recovery left no unfreeze trail** (`e200018`)
- Wrong: recovery cleared the lost wallet's freeze without an event, so freeze state rebuilt from events kept the retired wallet frozen.
- Fix: recovery emits `TokensUnfrozen` and `AddressFrozen(false)` for what it clears, before the move.
- Test: `test_forcedRecovery_emitsTheFullFreezeEventSequence`.

**10. `isVerified` read two slots** (`3b1ca76`)
- Wrong: the identity check, run twice per transfer, also loaded the investor id slot.
- Root cause: the record was copied to memory.
- Fix: the two fields are read through a storage pointer; the token's registry and engine references became `immutable`.
- Test: `test_isVerified_readsOneStorageSlot`.

**11. An edited terms document was anchored instead of rejected** (`b582a2a`)
- Wrong: the deployment hashed whatever the terms file contained and compared the anchor with the same file.
- Fix: `Deploy.s.sol` and `DeployTest` both pin the hash, and a drifted file fails the deployment.
- Test: `test_deploy_revertsWhenTermsDrift`.

**12. Module checks refused zero-amount transfers** (round 3, `8bfbdb8`)
- Wrong: the lockup, the holder cap and the country rule refused some zero-amount transfers (from a sender in lockup, to a non-holder at a full cap, to a blocked recipient) although nothing moved, while their hooks already ignored zero amounts.
- Fix: every module's `moduleCheck` returns true for a zero amount; the token-level identity, freeze and pause checks still apply.
- Tests: `test_zeroAmountTransfer_fromSenderInLockup_succeeds`, `test_zeroAmountTransfer_toNonHolderAtCap_succeedsWithoutCounting`, `test_zeroAmountTransfer_toBlockedCountry_succeeds`, `test_zeroAmountTransferFrom_passesModulesButNotTheGate`.

**13. `Deploy.run()` gave the roles to the wrong account when called from a contract** (round 2, `9fd4b4f`; round 3, `8c101b5`)
- Wrong: the role defaults read `msg.sender`, while a bare `vm.startBroadcast()` signs as `tx.origin`; from a test the wiring reverted. The run test also depended on the runner's environment.
- Fix: the defaults read `tx.origin` (the broadcasting account in an off-chain script; no contract reads it), the variables became `RWA_ISSUER`, `RWA_AGENT` and `RWA_CUSTODIAN`, and the unset case is modelled by a harness.
- Tests: `test_run_defaultsEveryRoleToTheBroadcaster`, `test_run_readsOperatorsFromTheEnvironment`. They replace `test_run_wiresTheSystemWithDefaultAndExplicitRoles`, which reverted with `AccessControlUnauthorizedAccount` against the `msg.sender` default.

## Introduced and fixed during the review

This defect was introduced in round 2 and fixed in the same round.

**1. Module attachment events named a caller-supplied address** (round 2, `a957a53`)
- Wrong: `bindCompliance` and `unbindCompliance` emitted the address they were passed.
- Fix: they emit the module's bound engine.
- Test: `test_bindCompliance_eventNamesTheBoundEngine`, written alongside the fix; no failing run against the unfixed code was captured.

## Hardening and documentation

These changes had no failing test behind them: one proves a mechanism that had no test, one corrects a document, one bounds a loop. None claims a regression test that failed before the change.

**1. The dividend remainder carry was untested, and its role overstated** (round 3, `ac714ff`)
- Wrong: zeroing `_residue` failed no test, because below a supply of 2^128 base units the carried remainder is worth less than one wei per deposit; the comments credited solvency to the carry.
- Fix: a test at a supply of 2^129 + 1, where a one-unit deposit moves the accumulator by zero on its own and only the carry lets three deposits pay out. The comments now say the carry defers the sub-unit remainder of each deposit and that the per-holder floor keeps the distributor solvent.
- Test: `test_deposit_residueCarriesSubUnitRemainderIntoLaterDeposits`. There was no bug to reproduce; the test is shown to matter by mutation: with `_residue` set to zero it fails.

**2. The terms document described an EU allowlist** (round 1, fixed in round 3, `f0c0f74`)
- Wrong: the anchored terms said "EU jurisdictions"; the code enforces a blocklist of restricted countries and has no EU rule.
- Fix: the terms describe the blocklist; both hash pins moved to the new content.
- Found by reading the terms against the code in round 1. The pinned hash from bug 11 then caught the edit itself: every deployment in the suite reverted with `TermsHashMismatch` until both pins were moved to the new content. No test covers the wording.

**3. The module fan-out had no bound** (round 3, `5fe0cdd`)
- Wrong: every transfer iterates all modules twice, and nothing capped their number.
- Fix: `MAX_MODULES = 25`, the T-REX limit; `addModule` reverts with `ModuleLimitReached` beyond it.
- Test: `test_addModule_capsTheModuleCount`, written with the cap; removing the cap makes it fail.

## Test-suite findings

| Finding (round 1) | Fix | Commit |
|---|---|---|
| The invariant handler caught every revert, so failures were invisible; two invariants could not fail | Reverts classified as expected or unexpected, with an invariant on the unexpected count; the two vacuous invariants replaced; zero amounts, `transferFrom`, the country block, recovery pairs and dividends added to the handler | `6fe5e72` |
| A bare `vm.expectRevert()`; the signer fuzz test only tested rejection | Selector-specific expectation; acceptance tested over the whole key range | `449351a` |
| The reentrancy test did not show a reentry was attempted; `deposit` and `forcedRecovery` had no reentrancy test | Mocks record the attempt and the error; new tests for both | `2697b72` |
| The 1-wei re-lock test dusted after expiry; the holder-count fuzz never transferred | Dust one second before expiry; random mints, transfers and burns with a recount | `eac33d3` |
| Engine and document tests checked less than their names said | From/to checked, every hook covered, a real swap-and-pop, interleaved anchors | `04c132d` |
| The composed-rules scenario could not tell the lockup from the country rule | Each module's own verdict asserted at every step | `67e4215` |
| Dividend fuzz bounds excluded small supplies; `uint96` parameters were truncated; exact rounding asserted | Bounds from one wei; `uint256` parameters; one-sided bounds with the reason | `fcc4baf` |
| Suite not runnable under `forge coverage` (stack too deep) | Handler wiring grouped in a struct; slot test counts distinct slots | `cc19618` |

## Documentation findings

Round 1 corrected the README and guides where they disagreed with the code: the test and coverage figures, the clone instructions, the contract count and role matrix, the "one SLOAD" claims, a claim that T-REX has this lockup model, the deploy script's hash check, and 92 em dashes (`d9b7f34`, `eb97a9a`, `baefb20`, `6b7c182`, `14c51bc`, `8a5b77e`). Round 2 brought the docs in line with its fixes (`fc6bb47`, `8530aaa`); round 3 added this section's final form, the conformance and edge case documentation, and the rewritten test catalogue.

---

**See also:**
- [Regressions](./tests/14-regressions.md) - the regression tests, numbered like the bugs above
- [Testing Documentation](./tests/README.md) - the full test catalogue
