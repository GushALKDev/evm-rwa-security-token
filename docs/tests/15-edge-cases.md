# Edge Cases (Review)

**Suites:** [`EdgeCasesTest`](../../test/scenario/EdgeCases.t.sol) (12 scenario)
**Covers:** boundaries and griefing vectors the unit suites do not reach, run against the system [`Deploy`](../../script/Deploy.s.sol) produces

---

> The unit suites pin each contract's own edges; the lifecycle scenarios walk the paths an operator expects. This suite sits between them: interactions between two mechanisms that each behave correctly alone (an identity expiring during a lockup, a pause against every role's actions, a settlement currency that returns `false`), and the extreme values the contracts accept. Several tests pin a behaviour that is documented rather than defended, and say so.

The distributor, where a test needs one, is registered with `addModule` after `_deploy`, as in the [dividend scenarios](./13-dividend-distributor.md#integration).

## Holder cap

| Test | Asserts |
| :--- | :------ |
| [`test_holderCap_loweredToCount_thenExitsAndEntries`](../../test/scenario/EdgeCases.t.sol#L70) | With two holders, a cap of 1 reverts `MaxHoldersBelowCurrentCount(1, 2)` and a cap of 2 is accepted; a mint to a third holder then reverts `ComplianceCheckFailed(0, carol, 1)`; a full-balance swap to the third holder settles with the count at 2; and after a burn empties one holder, a mint to a wallet that holds nothing is admitted with the count still at 2 |

This walks a placement lowered to exactly its current size through everything that can happen next: refusal, replacement and re-entry after an exit. The unit-level pieces are in [Max Holders Module](./05-max-holders-module.md#rule-admin).

---

## Lockup

| Test | Asserts |
| :--- | :------ |
| [`test_setLockupPeriod_appliesRetroactively`](../../test/scenario/EdgeCases.t.sol#L102) | A holder whose 365-day period has run is released (`canTransfer` true); doubling the period re-locks them (false), and shortening it to one day releases them again (true) |
| [`test_kycExpiryDuringLockupAndWithUnclaimedIncome`](../../test/scenario/EdgeCases.t.sol#L120) | A 30-day attestation expires inside the lockup with income unclaimed: a transfer reverts `SenderNotVerified` and a claim `ClaimantNotVerified`. After renewal the unlock time is unchanged and the claim pays the deposit less one wei |
| [`test_removingLockup_releasesLockedHolders_andCannotReturn`](../../test/scenario/EdgeCases.t.sol#L147) | Removing the lockup module lets a holder still inside the period transfer at once, and adding it back reverts `ModuleCannotBind` |

The first is the documented consequence of storing the clock *start* rather than a release date: the period is read at check time, so changing it moves every running clock in both directions. The third shows the other side of review finding 6: once a stateful module is removed, the release it caused cannot be undone by adding it back, because the module missed everything that moved while it was out.

---

## Recovery

| Test | Asserts |
| :--- | :------ |
| [`test_recovery_intoBlockedJurisdictionWalletOfSameInvestor`](../../test/scenario/EdgeCases.t.sol#L168) | With France blocked, recovery into a French-registered wallet of the same investor moves the whole balance: recovery skips the modular rules by design |
| [`test_recoveredLostWallet_cannotClaim`](../../test/scenario/EdgeCases.t.sol#L183) | After recovery with income unclaimed, the lost wallet's claim reverts `ClaimantNotVerified`; once the agent registers it again, the claim reverts `NothingToClaim`, and the new wallet is owed the deposit less at most one wei |

The first test asserts only the recovery itself. Its comment notes that the recovered position is then subject to the jurisdiction rule like any holding in France; that onward behaviour is not asserted here. The second closes the income side of eviction: re-registering a retired wallet does not bring its income back, because recovery already moved the entitlement.

---

## Dividends

| Test | Asserts |
| :--- | :------ |
| [`test_dividends_smallestSupplyAndDeposit`](../../test/scenario/EdgeCases.t.sol#L211) | With a supply of one base unit, a deposit of one currency unit is claimable exactly, and after a second the claim pays exactly 2 |
| [`test_dividends_directDonationIsNotCredited`](../../test/scenario/EdgeCases.t.sol#L226) | Currency sent straight to the distributor, outside `deposit`, leaves what the holder is owed unchanged |
| [`test_dividends_currencyReturningFalse_failsTheClaimCleanly`](../../test/scenario/EdgeCases.t.sol#L239) | With a currency whose `transfer` returns `false`, the claim reverts `SafeERC20FailedOperation` and records no withdrawal; with one that reverts, the claim reverts with the currency's own error; switched back to normal, the same claim pays the deposit less one wei |
| [`test_dividends_currencyReturningFalse_failsTheDepositCleanly`](../../test/scenario/EdgeCases.t.sol#L267) | With a currency whose `transferFrom` returns `false`, the deposit reverts `SafeERC20FailedOperation` and the accumulator stays at zero |

The two currency tests use `FlakyCurrency`, defined in the same file, which can be switched to return `false` or revert on transfers. A settlement token that signals failure by return value rather than by reverting is a known ERC-20 hazard; the distributor goes through `SafeERC20`, and these tests show a failed payout leaves no record, so it can be retried.

---

## Pause and roles

| Test | Asserts |
| :--- | :------ |
| [`test_pause_againstEachRoleAction`](../../test/scenario/EdgeCases.t.sol#L289) | While paused: mint, burn, transfer and `transferFrom` each revert `EnforcedPause`. Agent administration (both freezes, set and cleared, identity registration and removal, the holder cap, the lockup period, the country list), issuer module removal, a distributor deposit and a claim all complete, and custodian recovery moves the whole balance |

The pause stops every movement of the token except forced recovery, and nothing else. Freezes, identity changes and rule parameters stay available because they are how the desk responds to the incident the pause was called for; the distributor moves the settlement currency, not the token. This is the behaviour [Guide 7](../07-security.md#trust-assumptions-and-limitations) documents, pinned in one test so a change to it is visible.

---

## Document registry

| Test | Asserts |
| :--- | :------ |
| [`test_documents_longestNameAndLongUri`](../../test/scenario/EdgeCases.t.sol#L348) | A name with all 32 bytes set and a 4 KiB URI are anchored, and the URI reads back at its full 4096-byte length |

Names are fixed 32-byte labels, so a full 32-byte name is the longest there is; URIs have no length limit beyond gas, and 4 KiB is well above any real location.
