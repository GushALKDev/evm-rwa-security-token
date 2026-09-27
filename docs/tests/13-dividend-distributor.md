# Dividend Distributor (Phase 8)

**Suites:** [`DividendDistributorTest`](../../test/unit/DividendDistributor.t.sol) (42 unit + 5 fuzz) · [`DividendsTest`](../../test/scenario/Dividends.t.sol) (4 scenario)
**Covers:** roadmap items 8.1-8.4 · [Guide 6, dividend distribution](../06-improvements.md#6-dividend-distribution-built-in-phase-8)

---

> Income distribution is the first unit that accrues *value* to a holder rather than merely permitting or refusing their transfers. That changes what a test has to show: the other modules are correct when they answer yes or no correctly, this one is correct only if the money adds up. The suite found two real bugs while the unit was being built, and both are documented here rather than quietly fixed; the review later found a third (finding 5).

## What is being tested

The distributor pays income pro-rata without ever iterating the holder set, using the accumulator identity

```
accumulated(a) = balanceOf(a) * dividendsPerShare - correction(a)
```

where `correction` absorbs the error in pricing an account's *current* balance as if it had been held since inception. The tests fall into three groups: the arithmetic of that identity under every shape of balance movement, the rounding behaviour that decides whether the contract stays solvent, and the integration through the real engine and token.

The unit suite drives the hooks from a plain address standing in for the engine, against [`MockToken`](../../test/helpers/MockToken.sol), whose `recovering()`, `isFrozen()` and `isVerified()` answers each test can set.

---

## Constructor and attachment

| Test | Asserts |
| :--- | :------ |
| [`test_constructor_setsState`](../../test/unit/DividendDistributor.t.sol#L97) | Engine, token, currency, name and both roles are set, and the accumulator starts at zero |
| [`test_constructor_revertsOnZeroToken`](../../test/unit/DividendDistributor.t.sol#L107) | A zero token reverts `ZeroAddress`: balances define the split |
| [`test_constructor_revertsOnZeroCurrency`](../../test/unit/DividendDistributor.t.sol#L112) | A zero settlement currency reverts `ZeroAddress` |
| [`test_constructor_revertsOnZeroIssuer`](../../test/unit/DividendDistributor.t.sol#L117) | A zero issuer reverts `ZeroAddress`, which would leave the deposit path unreachable |
| [`test_constructor_revertsOnZeroCompliance`](../../test/unit/DividendDistributor.t.sol#L122) | A zero engine reverts `OnlyCompliance(0, 0)` from the shared `AbstractComplianceModule` constructor |
| [`test_attachment_lateOnceOnly`](../../test/unit/DividendDistributor.t.sol#L90) | The distributor is not plug and play; once attached, and with supply present, it is bound and `canComplianceBind` is false, so it cannot be attached a second time |

Unlike the holder cap and the lockup, the distributor may join a token that already has supply: its correction terms start from the balances at attach time. What it may not do is come back after a removal, because it would have missed every movement made while it was out (review finding 6). The deployed-wiring regressions are [`test_distributor_lateAttachSplitsLaterDeposits`](../../test/scenario/Regressions.t.sol#L420), [`test_addModule_rejectsReattachingARemovedDistributor`](../../test/scenario/Regressions.t.sol#L410) and [`test_distributor_afterRemoval_refusesDepositsAndPaysAccrued`](../../test/scenario/Regressions.t.sol#L437).

---

## Deposit

| Test | Asserts |
| :--- | :------ |
| [`test_deposit_pullsFundsAndRaisesAccumulator`](../../test/unit/DividendDistributor.t.sol#L131) | `DividendsDeposited` names the depositor, the currency is pulled into the distributor, and `dividendsPerShare` rises |
| [`test_deposit_revertsOnZeroAmount`](../../test/unit/DividendDistributor.t.sol#L142) | A zero deposit reverts `ZeroDeposit` rather than emitting a misleading event |
| [`test_deposit_revertsOnZeroSupply`](../../test/unit/DividendDistributor.t.sol#L151) | **Depositing against zero supply reverts `NoSupply`**: there is no one to credit and the funds would be stranded |
| [`test_deposit_revertsForNonAgent`](../../test/unit/DividendDistributor.t.sol#L157) | Deposits are AGENT-gated: an open deposit lets anyone perturb the accumulator |
| [`test_deposit_isReentrancyGuarded`](../../test/unit/DividendDistributor.t.sol#L615) | A settlement currency holding `AGENT_ROLE` reenters `deposit` from inside the `transferFrom` that pulls the funds: it records the attempt, the reentry fails with `ReentrancyGuardReentrantCall`, the distributor holds the deposit once, and the entitlement reflects one deposit |

The zero-supply guard is the non-obvious one. Dividing by a zero supply would revert anyway, but the custom error states the actual condition, and the alternative design (accepting the funds and holding them for future holders) silently changes who the money belongs to.

---

## Claiming

| Test | Asserts |
| :--- | :------ |
| [`test_claim_paysSoleHolderTheWholeDeposit`](../../test/unit/DividendDistributor.t.sol#L171) | A sole holder is owed the deposit within the one-wei bound, `DividendsClaimed` fires, the payout equals what was owed, and `claimable` then reads zero and `withdrawn` the amount paid |
| [`test_claim_splitsProRata`](../../test/unit/DividendDistributor.t.sol#L188) | Two holders at a 1:2 ratio are owed a third and two thirds, each within the one-wei bound |
| [`test_claim_canPayADifferentAddress`](../../test/unit/DividendDistributor.t.sol#L197) | A holder may direct payment elsewhere: the recipient receives what was owed and the holder receives nothing |
| [`test_claim_revertsOnZeroRecipient`](../../test/unit/DividendDistributor.t.sol#L210) | Paying the zero address reverts `ZeroAddress` |
| [`test_claim_revertsWhileFullyFrozen`](../../test/unit/DividendDistributor.t.sol#L220) | A fully frozen holder is refused with `ClaimantFrozen`, whatever they are owed |
| [`test_claim_revertsWhileUnverified`](../../test/unit/DividendDistributor.t.sol#L231) | A holder the registry does not verify is refused with `ClaimantNotVerified` |
| [`test_claim_entitlementAccruesWhileBlocked`](../../test/unit/DividendDistributor.t.sol#L243) | Two deposits made while a holder is both frozen and unverified are owed in full, within the one-wei bound, once both blocks are lifted, and the claim pays that amount |
| [`test_claim_revertsWhenNothingAccrued`](../../test/unit/DividendDistributor.t.sol#L260) | A non-holder claiming reverts `NothingToClaim` |
| [`test_claim_revertsOnSecondClaimWithoutNewIncome`](../../test/unit/DividendDistributor.t.sol#L269) | A second claim without new income reverts `NothingToClaim`, not a silent zero payment |
| [`test_claim_accruesAgainAfterASecondDeposit`](../../test/unit/DividendDistributor.t.sol#L280) | After a claim, a second deposit brings `accumulated` to two deposits: claiming does not detach the account from future income |
| [`test_claim_isReentrancyGuarded`](../../test/unit/DividendDistributor.t.sol#L593) | **A settlement currency reentering `claim` from inside its own `transfer`** records the attempt, the reentry fails with `ReentrancyGuardReentrantCall`, the claimant is paid exactly once, and nothing remains claimable |

**Frozen and unverified holders used to be paid** (review finding 5): `claim` read neither the token's freeze state nor the registry. The three blocking tests above are the unit form of the fix; the entitlement keeps accruing and is released when the block is lifted. The end-to-end regressions, including expired KYC and the partial-freeze case that must still pay, are under [finding 5](./14-regressions.md#5-frozen-and-unverified-holders-could-claim-income). The property also holds across arbitrary sequences as [`invariant_blockedHoldersAreNeverPaid`](../../test/invariant/Invariants.t.sol#L259).

The reentrancy tests use `ReenteringCurrency`, defined at the bottom of the suite. This is the realistic hostile shape for a pull-payment contract: the currency is external code that gets control mid-call. For `claim` the withdrawal record is written before the transfer, so the guard is the first line rather than the only one; for `deposit` the currency is given the agent role so that only the guard can stop the reentry.

---

## Correction accounting

The property the whole design rests on: a transfer moves shares, never entitlement.

| Test | Asserts |
| :--- | :------ |
| [`test_transfer_doesNotMoveAlreadyAccruedDividends`](../../test/unit/DividendDistributor.t.sol#L360) | **The seller keeps income earned while holding; the buyer is owed nothing for it** |
| [`test_transfer_shiftsFutureIncomeToTheBuyer`](../../test/unit/DividendDistributor.t.sol#L371) | After a full sale and a second deposit, each party is owed exactly one deposit |
| [`test_transfer_partialBalanceSplitsFutureIncome`](../../test/unit/DividendDistributor.t.sol#L381) | After a half-balance transfer, the next deposit splits in half |
| [`test_transfer_afterClaimLeavesNothingToDoubleClaim`](../../test/unit/DividendDistributor.t.sol#L391) | Claiming and then selling leaves neither party anything to claim, and the seller holds exactly what was paid |
| [`test_transfer_selfTransferDoesNotChangeEntitlement`](../../test/unit/DividendDistributor.t.sol#L407) | **A self-transfer after income leaves the entitlement unchanged**, the case that produced a live bug in `MaxHoldersModule` |
| [`test_transfer_selfTransferBeforeIncomeIsInert`](../../test/unit/DividendDistributor.t.sol#L416) | A self-transfer before any income also leaves the next deposit wholly owed to the holder |
| [`test_mint_afterIncomeGrantsNoBackpay`](../../test/unit/DividendDistributor.t.sol#L425) | A holder minted after a deposit is owed nothing from it, and the existing holder keeps it |
| [`test_burn_preservesAccruedDividends`](../../test/unit/DividendDistributor.t.sol#L436) | **Burning the whole position does not burn the income it already earned**: it stays owed and is paid in full |
| [`test_burn_stopsFutureAccrual`](../../test/unit/DividendDistributor.t.sol#L450) | After a burn, the burned holder is owed nothing and the remaining holder takes the whole of the next deposit |

The correction is what makes double-claiming across a transfer structurally impossible rather than merely unlikely: on any balance move the sender's correction falls by exactly what the recipient's rises, so the sum of `accumulated` over all accounts is untouched. Only a deposit ever raises it. Mint and burn are the one-sided cases of the same rule, which is why they need their own tests rather than being treated as transfers with a zero counterparty.

The self-transfer case is discarded explicitly rather than allowed to net out. The two updates would cancel exactly, but the equivalent inference in [`MaxHoldersModule`](./05-max-holders-module.md#counting-without-enumeration) did *not* cancel and produced a free denial of service, so the case is handled first and tested in both orderings.

---

## Rounding and solvency

This group exists because of a bug found here, and it is the most important section in the file.

| Test | Asserts |
| :--- | :------ |
| [`test_deposit_carriesResidueSoTheShortfallDoesNotGrow`](../../test/unit/DividendDistributor.t.sol#L296) | Across eight consecutive deposits to one holder, what is owed stays within one wei below the total deposited, and the carried residue stays below one share |
| [`test_deposit_residueCarriesSubUnitRemainderIntoLaterDeposits`](../../test/unit/DividendDistributor.t.sol#L318) | **What the residue is for.** With a supply of 2^129 + 1, two one-unit deposits leave the accumulator at zero with 2^129 carried; the third moves it to 1 and the holder is owed 2. Without the carry the holder would be owed nothing however many deposits arrived. Regression test for review finding 13 |
| [`test_deposit_claimsNeverExceedFundsAcrossManyDeposits`](../../test/unit/DividendDistributor.t.sol#L337) | **Regression: after each of twelve deposits to two holders, claimable plus withdrawn never exceeds the funds deposited**, and both holders can then claim |

**The bug.** The residue left by each deposit's truncated division was first carried in *currency* units, as "deposited minus what the accumulator will pay out". That rounds the dust **up** every deposit and the error compounds: by the third deposit the sum of claims already exceeded the sum of deposits, and the gap grew by one wei per deposit thereafter. The contract would have become unable to pay its last claimant, with no bound on how far short it fell.

The fix is to carry the raw modulus in **scaled** units (`scaled % supply`). Every deposit is then exact to within the single final truncation in `accumulated`, so the per-holder shortfall is under one wei and always points the same way: the contract holds slightly more than it owes, never less.

This is why payout assertions in this suite use a deliberately one-sided helper (`_assertOwed`): the value must be at most the exact share and at most one wei below it. Rounding down is the mechanism that keeps the contract solvent, so an exact-equality assertion would pin a rounding direction the design does not promise, and a two-sided tolerance would accept an overpayment.

---

## Forced recovery

| Test | Asserts |
| :--- | :------ |
| [`test_recovery_carriesEntitlementToTheNewWallet`](../../test/unit/DividendDistributor.t.sol#L466) | **Recovery relocates the position whole**: the new wallet is owed exactly what the lost one was, and the lost wallet is owed nothing |
| [`test_recovery_lostWalletCannotClaimAfterwards`](../../test/unit/DividendDistributor.t.sol#L483) | The lost wallet's claim reverts `NothingToClaim` |
| [`test_recovery_carriesTheWithdrawalRecord`](../../test/unit/DividendDistributor.t.sol#L498) | The `withdrawn` record moves to the new wallet and is cleared on the old one, so recovery cannot re-open a settled claim |
| [`test_recovery_newWalletAccruesFutureIncome`](../../test/unit/DividendDistributor.t.sol#L516) | After recovery, the next deposit is owed wholly to the new wallet |

**The second bug, and the more serious one.** Settling a recovery like an ordinary sale leaves the unclaimed income on the lost wallet, precisely the wallet the investor no longer controls. This was reproduced end to end before it was fixed: after a successful `forcedRecovery`, the compromised address still drained the full deposit. The tokens were rescued and the money was not.

The accumulator cannot distinguish the two cases on its own, because `moduleTransferred(from, to, amount)` is byte-identical for a sale and a recovery while the two mean opposite things for anything that accrues value. `SecurityToken` therefore exposes a `recovering()` view over its internal flag, and the hook branches on it. Carrying `withdrawn` alongside `correction` matters as much as the correction itself: without it the new wallet could re-claim income the old one had already been paid.

This is the one place the distributor depends on the token being a `SecurityToken` rather than any ERC-20, and it is a real seam in the module abstraction; see [Trade-offs](../04-tradeoffs.md). What happens when the lost wallet was already suspended, or tries to claim after being re-registered, is in [`test_recoveredLostWallet_cannotClaim`](../../test/scenario/EdgeCases.t.sol#L183).

---

## Module surface

| Test | Asserts |
| :--- | :------ |
| [`test_moduleCheck_alwaysPermits`](../../test/unit/DividendDistributor.t.sol#L534) | **The distributor never blocks a transfer**: true for a transfer, a mint, a burn and a zero-amount call between zero addresses |
| [`test_moduleTransferred_revertsForNonCompliance`](../../test/unit/DividendDistributor.t.sol#L545) | Only the bound engine may drive `moduleTransferred` |
| [`test_moduleCreated_revertsForNonCompliance`](../../test/unit/DividendDistributor.t.sol#L551) | Only the bound engine may drive `moduleCreated` |
| [`test_moduleDestroyed_revertsForNonCompliance`](../../test/unit/DividendDistributor.t.sol#L557) | Only the bound engine may drive `moduleDestroyed` |

`moduleCheck` returning an unconditional `true` is a design statement, not a stub: the distributor is an observer that keeps accounts, not a rule that expresses a restriction. Withholding income from a blocked holder is done at `claim`, not at the transfer gate. The test pins that so a future change cannot quietly turn income accounting into a transfer restriction.

The hook gating is not ceremonial here. An ungated `moduleTransferred` would let anyone shift corrections between accounts and give themselves an arbitrary entitlement against real deposited funds.

---

## Fuzz

| Test | Asserts |
| :--- | :------ |
| [`testFuzz_conservation_claimsNeverExceedDeposits`](../../test/unit/DividendDistributor.t.sol#L640) | For two holders with up to 1e30 shares each and one deposit up to 1e18, the total owed never exceeds the deposit |
| [`testFuzz_roundingDustIsBounded`](../../test/unit/DividendDistributor.t.sol#L658) | In the same domain, the two holders together are owed at least the deposit minus two wei: one wei per holder, not an unbounded leak |
| [`testFuzz_transferPreservesTotalEntitlement`](../../test/unit/DividendDistributor.t.sol#L674) | A transfer of any part of a position after a deposit leaves the sum of entitlements exactly unchanged |
| [`testFuzz_solventAcrossRepeatedDeposits`](../../test/unit/DividendDistributor.t.sol#L693) | **Over 1 to 20 deposits, the distributor always holds at least what it says is owed**, and the holders fall short of the total deposited by at most two wei however many deposits there were |
| [`testFuzz_claimIsAlwaysSolvent`](../../test/unit/DividendDistributor.t.sol#L724) | After a deposit and a transfer of any part, each non-zero entitlement is claimable and pays exactly the amount reported |

`testFuzz_solventAcrossRepeatedDeposits` is the one that would have caught the compounding-residue bug, and it is deliberately multi-deposit: the single-deposit properties all passed while the contract was insolvent, because the error only appears once a second deposit is folded in. Its lower bound is the other half: a shortfall that grew with the number of deposits would mean the residue leaks.

The group is run deeper than the default before the unit is trusted, with `FOUNDRY_FUZZ_RUNS=20000 forge test --match-contract DividendDistributorTest`. The default 256 runs are not evidence for arithmetic this sensitive to rounding. Solvency and conservation also hold as stateful invariants across interleavings with freeze, pause, identity withdrawal and recovery: [`invariant_dividendsSolvent`](../../test/invariant/Invariants.t.sol#L239) and [`invariant_dividendsConserved`](../../test/invariant/Invariants.t.sol#L250).

---

## Integration

The unit suite drives the hooks from a mocked engine address, which shows the arithmetic but not the wiring. These run against the system `Deploy` produces, with the real engine, registry, token and all three rule modules.

| Test | Asserts |
| :--- | :------ |
| [`test_scenario_incomeAccruesToTheHolderAtTheTimeOfDeposit`](../../test/scenario/Dividends.t.sol#L77) | Subscribe, receive income, sell after the lockup: the seller keeps the first deposit, the buyer is owed nothing from it and the whole of the second, and the two payouts together are within two wei below the two deposits, never above |
| [`test_scenario_recoveryCarriesUnclaimedIncome`](../../test/scenario/Dividends.t.sol#L117) | **Through the real `forcedRecovery`**, the unclaimed income moves to the new wallet, the lost wallet is owed nothing, and the new wallet's claim pays it |
| [`test_scenario_distributorDoesNotGateTransfers`](../../test/scenario/Dividends.t.sol#L143) | With the distributor registered and income deposited, `canTransfer` is true after the lockup and the transfer settles |
| [`test_scenario_multiHolderDistributionStaysSolvent`](../../test/scenario/Dividends.t.sol#L162) | Five deposits across two holders: the total owed stays within the funds deposited and within the distributor's balance, and both holders can claim |

The suite registers the distributor with `addModule` **after** `_deploy` has already closed the graph. That is the point rather than a convenience: it shows that a new capability is added to a live system without redeploying anything and without touching the token, which is the claim the module architecture makes.

---

## Infrastructure

- [`MockCurrency`](../../test/helpers/MockCurrency.sol) is deliberately **6-decimal**, matching a real stablecoin rather than the 18-decimal token. A distributor tested only against an 18-decimal currency hides precision bugs that appear when the settlement currency is far coarser than the security token, which is the real configuration.
- [`MockToken`](../../test/helpers/MockToken.sol) answers the token queries the distributor makes (`recovering()`, `isFrozen()`, and `isVerified()` through `identityRegistry()` pointing back at itself), each settable from the test. Every wallet reads as verified and unfrozen unless a test says otherwise.
- `ReenteringCurrency`, in the suite file, is a `MockCurrency` that makes one reentrant call from `transfer` or `transferFrom` and records whether it was attempted and how it ended.

---

## References

- [Testing index](./README.md)
- [Guide 2: Mathematics §8](../02-mathematics.md#8-dividend-accrual-without-enumeration): the accumulator, the correction, and why recovery needs its own branch
- [Max Holders Module](./05-max-holders-module.md): the self-transfer inference bug this module deliberately avoids repeating
- [Security Token](./07-security-token.md): the `_update` branches, including the recovery path these hooks observe
- [Invariant Suite](./11-invariants.md): the dividend invariants and the deeper-run practice
- [Guide 6: Improvements](../06-improvements.md#6-dividend-distribution-built-in-phase-8): the design as originally specified
