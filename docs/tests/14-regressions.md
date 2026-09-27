# Regressions (Review)

**Suites:** [`RegressionsTest`](../../test/scenario/Regressions.t.sol) (29 scenario)
**Covers:** the [README review notes](../../README.md#bugs-in-the-reviewed-code), bugs 1 to 9 and 12

---

> One test per bug found in the review rounds, run against the system [`Deploy`](../../script/Deploy.s.sol) produces. Each of these bugs was reproduced first, got a regression test that failed against the unfixed code, and was then fixed. The sections below follow the numbering and the wording of the "Bugs in the reviewed code" block of the README's review notes, so a bug can be traced from the README to its tests and back. Three tests are the exception: they pin paths a fix leaves open and passed before it too. They are `test_claim_allowedUnderPartialFreeze` in the section for bug 5, and `test_distributor_lateAttachSplitsLaterDeposits` and `test_addModule_statelessModuleCanBeReattached` in the section for bug 6.
>
> The other findings are about one contract or the deployment script, so their tests live in the unit suites. They are listed in [Findings tested in the unit suites](#findings-tested-in-the-unit-suites) at the end of this page.

## 1. Zero amounts deflated the holder count

A zero-amount transfer from a verified wallet holding nothing lowered `MaxHoldersModule.holderCount`, because the hook reads `balanceOf(from) == 0` after the move as "the sender left". `transferFrom(emptyWallet, x, 0)` needs no allowance, so any address could drain the count. The fix: every stateful hook returns early on a zero amount.

| Test | Asserts |
| :--- | :------ |
| [`test_zeroAmountTransfer_doesNotDeflateHolderCount`](../../test/scenario/Regressions.t.sol#L99) | With the cap at the two current holders, two zero-amount sends from an empty verified wallet leave the count at 2, a mint to a third holder still reverts `ComplianceCheckFailed(0, carol, 1)`, and a recount of the wallets finds 2 holders |
| [`test_zeroAmountTransferFromByStranger_doesNotDeflateHolderCount`](../../test/scenario/Regressions.t.sol#L121) | An address with no role and no allowance calls `transferFrom(emptyWallet, holder, 0)`, and the count stays at 1 |
| [`test_zeroBurnFromNonHolder_doesNotDeflateHolderCount`](../../test/scenario/Regressions.t.sol#L133) | An issuer burn of zero from a wallet that holds nothing leaves the count at 1 |
| [`test_zeroAmountSends_doNotBlockLaterExits`](../../test/scenario/Regressions.t.sol#L144) | After three zero-amount `transferFrom` calls by a stranger, a holder's full exit to another holder settles (it used to underflow), and the count and a recount both read 1 |

The first test is the one that shows the cap-bypass consequence; the last shows the underflow consequence.

---

## 2. An unsubmitted attestation could undo a removal

An attestation issued while an investor was registered, but never submitted, re-registered them after the agent removed them, because only a signed registration advanced the nonce. The fix: every write to a record advances the nonce (unit test: [`test_nonces_advanceOnAgentWritesAndRemoval`](../../test/unit/IdentityRegistry.t.sol#L408)).

| Test | Asserts |
| :--- | :------ |
| [`test_attestationSignedBeforeRemoval_isRejectedAfterIt`](../../test/scenario/Regressions.t.sol#L172) | A valid, unexpired attestation signed before the agent removed the investor reverts `InvalidAttestationSigner` when a stranger submits it afterwards, and the investor stays unverified |
| [`test_attestationSignedBeforeAgentUpdate_isRejectedAfterIt`](../../test/scenario/Regressions.t.sol#L190) | An attestation for Spain signed before the agent registered the investor in France reverts `InvalidAttestationSigner`, and the country stays France: a stale signature cannot roll the record back |

Both use `expectPartialRevert`, because the address recovered from a signature over a stale nonce is not predictable.

---

## 3. A suspended wallet could not be recovered

After the agent removed a wallet's identity, `forcedRecovery` reverted with `RecoveryAcrossInvestors(0, id)`, because `removeIdentity` deleted the whole record, `investorId` included. The fix: removal keeps `investorId`, and recovery skips its own removal call when the wallet is already removed.

| Test | Asserts |
| :--- | :------ |
| [`test_forcedRecovery_succeedsAfterAgentRemovedLostWallet`](../../test/scenario/Regressions.t.sol#L213) | After the agent removes the lost wallet, its `investorId` is still the shared id, the custodian's recovery moves the whole balance to the investor's other wallet, and the lost wallet stays unverified |

---

## 4. Forced recovery restarted the lockup

Recovering a position into an empty wallet locked the investor again for the full period, because the recovery hook is the ordinary transfer hook, which `LockupModule` read as a fresh acquisition. The fix: `LockupModule` asks the token `recovering()` and moves the start instead (unit tests under [Lockup Module, forced recovery](./04-lockup-module.md#forced-recovery)).

| Test | Asserts |
| :--- | :------ |
| [`test_forcedRecovery_keepsAnExpiredLockupExpired`](../../test/scenario/Regressions.t.sol#L239) | Recovered after the lockup expired, the new wallet carries the original start, the lost wallet has no clock, and the new wallet can transfer straight away |
| [`test_forcedRecovery_keepsTheOriginalUnlockTime`](../../test/scenario/Regressions.t.sol#L260) | Recovered 100 days into the lockup, the new wallet's unlock time equals the lost wallet's original one |
| [`test_forcedRecovery_intoHoldingWallet_keepsTheEarlierStart`](../../test/scenario/Regressions.t.sol#L277) | Recovered into a wallet of the same investor that acquired 30 days later, the destination takes the earlier start |

---

## 5. Frozen and unverified holders could claim income

`DividendDistributor.claim` paid a holder who was fully frozen or no longer verified, because it read neither the token's freeze state nor the registry. The fix: `claim` reverts with `ClaimantFrozen` or `ClaimantNotVerified` (an expired KYC counts); the entitlement keeps accruing and is released when the block is lifted, and a partial freeze does not block a claim.

| Test | Asserts |
| :--- | :------ |
| [`test_claim_blockedWhileFullyFrozen_releasedAfterUnfreeze`](../../test/scenario/Regressions.t.sol#L300) | With one deposit before a full freeze and one during it, the claim reverts `ClaimantFrozen`; after unfreezing, what is owed is at least both deposits less one wei, and the claim pays exactly that |
| [`test_claim_blockedWhileUnverified_releasedAfterReverification`](../../test/scenario/Regressions.t.sol#L323) | After `removeIdentity` the claim reverts `ClaimantNotVerified`; after re-registration it pays the deposit less one wei |
| [`test_claim_blockedAfterKycExpiry`](../../test/scenario/Regressions.t.sol#L342) | Once a 30-day attestation expires, the claim reverts `ClaimantNotVerified` |
| [`test_claim_allowedUnderPartialFreeze`](../../test/scenario/Regressions.t.sol#L357) | With the whole balance under a partial freeze (but no full freeze), the claim pays the deposit less one wei: a partial freeze holds a lot of tokens, not the holder. It pins a path the fix leaves open and passed before the fix as well |

The distributor is registered with `addModule` after `_deploy`, so the freeze and verification it reads are the real token's and registry's. The stateful form is [`invariant_blockedHoldersAreNeverPaid`](../../test/invariant/Invariants.t.sol#L259).

---

## 6. Stateful modules could be attached where they could not keep up

A holder cap added to a token with holders started at zero and made the first exit underflow; a late lockup had no clock for existing holders; a distributor removed and added back overpaid holders who bought while it was out. `addModule` and `removeModule` reconciled nothing with existing balances. The fix is the T-REX `isPlugAndPlay` / `canComplianceBind` shape (unit tests under [Modular Compliance, attachment](./03-modular-compliance.md#attachment-the-plug-and-play-shape)).

| Test | Asserts |
| :--- | :------ |
| [`test_addModule_rejectsMaxHoldersOnceSupplyExists`](../../test/scenario/Regressions.t.sol#L376) | A new holder-cap module offered once the token has supply reverts `ModuleCannotBind` |
| [`test_addModule_rejectsLockupOnceSupplyExists`](../../test/scenario/Regressions.t.sol#L387) | A new lockup module offered once the token has supply reverts `ModuleCannotBind` |
| [`test_addModule_rejectsReattachingARemovedStatefulModule`](../../test/scenario/Regressions.t.sol#L398) | The deployed lockup and holder-cap modules, each removed, revert `ModuleCannotBind` when added back, with no supply at all |
| [`test_addModule_rejectsReattachingARemovedDistributor`](../../test/scenario/Regressions.t.sol#L410) | A distributor removed after being attached reverts `ModuleCannotBind` when added back |
| [`test_distributor_afterRemoval_refusesDepositsAndPaysAccrued`](../../test/scenario/Regressions.t.sol#L437) | After removal, a deposit reverts `DistributorNotAttached`, and income accrued before the removal is still paid (the deposit less one wei) |
| [`test_distributor_lateAttachSplitsLaterDeposits`](../../test/scenario/Regressions.t.sol#L420) | A distributor attached once to a token that already has holders at 1:3 splits its first deposit 200/600, each within one wei below |
| [`test_addModule_statelessModuleCanBeReattached`](../../test/scenario/Regressions.t.sol#L454) | The country module, removed with supply present, is added back and registered |

The last two are not in the README's list for this finding; they pin the two cases the fix deliberately still allows, so that it cannot be tightened into refusing them. The follow-up commit of the finding (the attachment events name the bound engine) is the entry under "Introduced and fixed during the review", tested in the unit suite, see [below](#findings-tested-in-the-unit-suites).

---

## 7. A module could read a different token than the engine's

A stateful module built against another token was accepted and then counted that token's balances, because `addModule` checked only that the module named this engine. The fix: `addModule` and `bindToken` reject a module whose `token()` differs from the bound token.

| Test | Asserts |
| :--- | :------ |
| [`test_addModule_rejectsModuleBuiltForAnotherToken`](../../test/scenario/Regressions.t.sol#L470) | On the deployed engine, a holder-cap module built for another token reverts `ModuleTokenMismatch(module, otherToken, boundToken)` |
| [`test_bindToken_rejectsRegisteredModuleForAnotherToken`](../../test/scenario/Regressions.t.sol#L484) | On a fresh engine with a lockup module for another token already registered, binding the deployed token reverts `ModuleTokenMismatch` |

---

## 8. An over-burn panicked

Burning more than the balance of a wallet with frozen tokens reverted with an arithmetic panic, because the frozen-portion arithmetic ran before the ERC-20 balance check.

| Test | Asserts |
| :--- | :------ |
| [`test_burn_aboveBalance_revertsWithInsufficientBalance`](../../test/scenario/Regressions.t.sol#L504) | With one wei frozen, burning one wei more than the balance reverts `ERC20InsufficientBalance(holder, balance, requested)` |

---

## 9. Recovery left no unfreeze trail

Recovery cleared the lost wallet's freeze without an event, so freeze state rebuilt from events kept the retired wallet frozen. The fix: recovery emits `TokensUnfrozen` and `AddressFrozen(false)` for what it clears, before the move.

| Test | Asserts |
| :--- | :------ |
| [`test_forcedRecovery_emitsTheFullFreezeEventSequence`](../../test/scenario/Regressions.t.sol#L525) | Recovering a wallet that is both partially and fully frozen, the token emits exactly six events in this order: `TokensUnfrozen` and `AddressFrozen` for the lost wallet, `Transfer`, `TokensFrozen` and `AddressFrozen` for the new wallet, and `RecoverySuccess`. Each names the expected wallet, the unfreeze carries the partial amount, and the first `AddressFrozen` carries `false` |

The test records the logs and filters to the token's own events, so events from the modules and the registry do not affect the order it checks.

---

## 12. Module checks refused zero-amount transfers

The lockup, the holder cap and the country rule refused some zero-amount transfers (from a sender in lockup, to a non-holder at a full cap, to a blocked recipient) although nothing moved, while their hooks already ignored zero amounts after finding 1. The fix: every module's `moduleCheck` returns true for a zero amount; the token-level identity, freeze and pause checks still apply. The unit counterparts are the `zeroAmount` checks in the [lockup](./04-lockup-module.md#enforcement-and-the-boundary-to-the-second), [holder cap](./05-max-holders-module.md#enforcement) and [country](./06-country-restriction.md#enforcement-and-why-it-is-recipient-side) suites.

| Test | Asserts |
| :--- | :------ |
| [`test_zeroAmountTransfer_fromSenderInLockup_succeeds`](../../test/scenario/Regressions.t.sol#L584) | A sender inside the lockup sends zero; it settles, the clock is unchanged and the balance is intact |
| [`test_zeroAmountTransfer_toNonHolderAtCap_succeedsWithoutCounting`](../../test/scenario/Regressions.t.sol#L601) | With the cap full, a zero-amount transfer to a wallet holding nothing settles and the count stays at the cap |
| [`test_zeroAmountTransfer_toBlockedCountry_succeeds`](../../test/scenario/Regressions.t.sol#L620) | A zero-amount transfer to a verified recipient in a blocked country settles, and one wei to the same recipient reverts `ComplianceCheckFailed` |
| [`test_zeroAmountTransferFrom_passesModulesButNotTheGate`](../../test/scenario/Regressions.t.sol#L641) | A stranger's zero-amount `transferFrom` between two verified holders emits `Transfer(from, to, 0)`; the same call reverts `RecipientAddressFrozen` once the recipient is frozen, and `RecipientNotVerified` to an unregistered wallet |

The last test is the boundary: the modules step aside for a zero amount, the token's own identity and freeze checks do not. In the invariant handler a `ComplianceCheckFailed` on a zero amount is therefore classified as an unexpected revert, see [revert classification](./11-invariants.md#revert-classification).

---

## Findings tested in the unit suites

These entries concern one contract or the deployment script, so their tests sit next to the rest of that contract's tests. The names and numbers are the README's, in its three blocks: bugs in the reviewed code, the defect introduced and fixed during the review, and hardening and documentation. Only the bugs have a regression test that failed against the unfixed code.

| Entry | Tested by | Documented in |
| :---- | :-------- | :------------ |
| Bug 10. `isVerified` read two slots | [`test_isVerified_readsOneStorageSlot`](../../test/unit/IdentityRegistry.t.sol#L423) | [Identity Registry, expiry](./02-identity-registry.md#expiry) |
| Bug 11. An edited terms document was anchored instead of rejected | [`test_deploy_revertsWhenTermsDrift`](../../test/unit/Deploy.t.sol#L283) | [Deployment, the document anchor](./09-deploy.md#the-document-anchor-52) |
| Hardening 1. The dividend remainder carry was untested, and its role overstated | [`test_deposit_residueCarriesSubUnitRemainderIntoLaterDeposits`](../../test/unit/DividendDistributor.t.sol#L318) | [Dividend Distributor, rounding and solvency](./13-dividend-distributor.md#rounding-and-solvency) |
| Hardening 2. The terms document described an EU allowlist | [`test_anchor_termsFileMatchesPinnedHash`](../../test/unit/Deploy.t.sol#L275), [`test_deploy_revertsWhenTermsDrift`](../../test/unit/Deploy.t.sol#L283) | [Deployment, the document anchor](./09-deploy.md#the-document-anchor-52) |
| Hardening 3. The module fan-out had no bound | [`test_addModule_capsTheModuleCount`](../../test/unit/ModularCompliance.t.sol#L195) | [Modular Compliance, module admin](./03-modular-compliance.md#module-admin-25) |
| Bug 13. `Deploy.run()` gave the roles to the wrong account when called from a contract | [`test_run_defaultsEveryRoleToTheBroadcaster`](../../test/unit/Deploy.t.sol#L211), [`test_run_readsOperatorsFromTheEnvironment`](../../test/unit/Deploy.t.sol#L229) | [Deployment, `run()` end to end](./09-deploy.md#run-end-to-end) |
| Introduced 1. Module attachment events named a caller-supplied address | [`test_bindCompliance_eventNamesTheBoundEngine`](../../test/unit/ModularCompliance.t.sol#L171) | [Modular Compliance, attachment](./03-modular-compliance.md#attachment-the-plug-and-play-shape) |

The review's test-suite findings (changes to the tests themselves rather than to the contracts) are summarised in the [strategy](./01-strategy.md#5-what-the-review-changed-in-the-tests).
