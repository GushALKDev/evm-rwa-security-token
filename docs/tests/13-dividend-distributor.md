# Dividend Distributor (Phase 8)

**Suites:** [`DividendDistributorTest`](../../test/unit/DividendDistributor.t.sol) (36 unit + 5 fuzz) · [`DividendsTest`](../../test/scenario/Dividends.t.sol) (4 scenario)
**Covers:** roadmap items 8.1-8.4 · [Guide 6, dividend distribution](../06-improvements.md#6-dividend-distribution-the-planned-stretch-unit)

---

> Income distribution is the first unit that accrues *value* to a holder rather than merely permitting or refusing their transfers. That changes what a test has to prove: the other modules are correct when they answer yes or no correctly, this one is correct only if the money adds up. Two of its tests found real bugs, and both are documented here rather than quietly fixed.

## What is being tested

The distributor pays income pro-rata without ever iterating the holder set, using the accumulator identity

```
accumulated(a) = balanceOf(a) * dividendsPerShare - correction(a)
```

where `correction` absorbs the error in pricing an account's *current* balance as if it had been held since inception. The tests fall into three groups: the arithmetic of that identity under every shape of balance movement, the rounding behaviour that decides whether the contract stays solvent, and the integration through the real engine and token.

---

## Constructor

| Test | Asserts |
| :--- | :------ |
| [`test_constructor_setsState`](../../test/unit/DividendDistributor.t.sol#L86) | Engine, token, currency and both roles are set, and the accumulator starts at zero |
| [`test_constructor_revertsOnZeroToken`](../../test/unit/DividendDistributor.t.sol#L96) | A zero token is refused: balances define the split |
| [`test_constructor_revertsOnZeroCurrency`](../../test/unit/DividendDistributor.t.sol#L101) | A zero settlement currency is refused |
| [`test_constructor_revertsOnZeroIssuer`](../../test/unit/DividendDistributor.t.sol#L106) | A zero issuer is refused, which would leave the deposit path permanently unreachable |
| [`test_constructor_revertsOnZeroCompliance`](../../test/unit/DividendDistributor.t.sol#L111) | A zero engine is refused by the shared `AbstractComplianceModule` binding |

---

## Deposit

| Test | Asserts |
| :--- | :------ |
| [`test_deposit_pullsFundsAndRaisesAccumulator`](../../test/unit/DividendDistributor.t.sol#L120) | The currency is pulled from the depositor and `dividendsPerShare` rises |
| [`test_deposit_revertsOnZeroAmount`](../../test/unit/DividendDistributor.t.sol#L131) | A zero deposit is refused rather than emitting a misleading event |
| [`test_deposit_revertsOnZeroSupply`](../../test/unit/DividendDistributor.t.sol#L140) | **Depositing against zero supply is refused**, since there is no one to credit and the funds would be stranded permanently |
| [`test_deposit_revertsForNonAgent`](../../test/unit/DividendDistributor.t.sol#L146) | Deposits are AGENT-gated: an open deposit lets anyone perturb the accumulator |

The zero-supply guard is the non-obvious one. Dividing by a zero supply would revert anyway, but the custom error states the actual condition, and the alternative design — accepting the funds and holding them for future holders — silently changes who the money belongs to.

---

## Claiming

| Test | Asserts |
| :--- | :------ |
| [`test_claim_paysSoleHolderTheWholeDeposit`](../../test/unit/DividendDistributor.t.sol#L160) | A sole holder receives the deposit, less the one-wei descaling truncation |
| [`test_claim_splitsProRata`](../../test/unit/DividendDistributor.t.sol#L177) | Two holders at a 1:2 ratio receive a 1:2 split |
| [`test_claim_canPayADifferentAddress`](../../test/unit/DividendDistributor.t.sol#L186) | A holder may direct payment elsewhere, without the entitlement following the recipient |
| [`test_claim_revertsOnZeroRecipient`](../../test/unit/DividendDistributor.t.sol#L199) | Paying the zero address is refused |
| [`test_claim_revertsWhenNothingAccrued`](../../test/unit/DividendDistributor.t.sol#L208) | A non-holder cannot claim |
| [`test_claim_revertsOnSecondClaimWithoutNewIncome`](../../test/unit/DividendDistributor.t.sol#L217) | A second claim without new income is refused, not silently paid zero |
| [`test_claim_accruesAgainAfterASecondDeposit`](../../test/unit/DividendDistributor.t.sol#L228) | Claiming does not detach the account from future income |
| [`test_claim_isReentrancyGuarded`](../../test/unit/DividendDistributor.t.sol#L486) | **A malicious settlement currency reentering `claim` from inside its own `transfer` is rejected by the guard** |

The reentrancy test uses a currency contract that calls back into `claim` mid-transfer. This is the realistic hostile shape for a pull-payment contract: the currency is external code that gets control after the withdrawal is recorded. The withdrawal record is written before the transfer (CEI), so the guard is the second line rather than the only one, but a token with a transfer callback makes it load-bearing.

---

## Correction accounting

The property the whole design rests on: a transfer moves shares, never entitlement.

| Test | Asserts |
| :--- | :------ |
| [`test_transfer_doesNotMoveAlreadyAccruedDividends`](../../test/unit/DividendDistributor.t.sol#L278) | **The seller keeps income earned while holding; the buyer is not paid for it** |
| [`test_transfer_shiftsFutureIncomeToTheBuyer`](../../test/unit/DividendDistributor.t.sol#L289) | The next deposit accrues entirely to the buyer |
| [`test_transfer_partialBalanceSplitsFutureIncome`](../../test/unit/DividendDistributor.t.sol#L299) | A half-balance transfer splits future income in half |
| [`test_transfer_afterClaimLeavesNothingToDoubleClaim`](../../test/unit/DividendDistributor.t.sol#L309) | Claiming and then selling leaves neither party able to claim the same income twice |
| [`test_transfer_selfTransferDoesNotChangeEntitlement`](../../test/unit/DividendDistributor.t.sol#L325) | **A self-transfer is inert**, the same inference that produced a live bug in `MaxHoldersModule` |
| [`test_transfer_selfTransferBeforeIncomeIsInert`](../../test/unit/DividendDistributor.t.sol#L334) | The same before any income exists, which trips a different branch |
| [`test_mint_afterIncomeGrantsNoBackpay`](../../test/unit/DividendDistributor.t.sol#L343) | A late arrival is not retroactively paid for earlier deposits |
| [`test_burn_preservesAccruedDividends`](../../test/unit/DividendDistributor.t.sol#L354) | **Burning shares does not burn the income they already earned** |
| [`test_burn_stopsFutureAccrual`](../../test/unit/DividendDistributor.t.sol#L368) | After a burn, the remaining holder takes the whole of the next deposit |

The correction is what makes double-claiming across a transfer structurally impossible rather than merely unlikely: on any balance move the sender's correction falls by exactly what the recipient's rises, so the sum of `accumulated` over all accounts is untouched. Only a deposit ever raises it. Mint and burn are the one-sided cases of the same rule, which is why they need their own tests rather than being treated as transfers with a zero counterparty.

The self-transfer case is discarded explicitly rather than allowed to net out. The two updates would cancel exactly, but the equivalent inference in [`MaxHoldersModule`](./05-max-holders-module.md#counting-without-enumeration) did *not* cancel and produced a free denial-of-service, so the case is handled first and tested in both orderings.

---

## Rounding and solvency

This group exists because of a bug found here, and it is the most important section in the file.

| Test | Asserts |
| :--- | :------ |
| [`test_deposit_carriesResidueSoTheShortfallDoesNotGrow`](../../test/unit/DividendDistributor.t.sol#L242) | Across eight consecutive deposits the shortfall stays at one wei and does not accumulate |
| [`test_deposit_claimsNeverExceedFundsAcrossManyDeposits`](../../test/unit/DividendDistributor.t.sol#L255) | **Regression: the sum of entitlements never exceeds the funds deposited, at any depth** |

**The bug.** The residue left by each deposit's truncated division was first carried in *currency* units, as "deposited minus what the accumulator will pay out". That rounds the dust **up** every deposit and the error compounds: by the third deposit the sum of claims already exceeded the sum of deposits, and the gap grew by one wei per deposit thereafter. The contract would have become unable to pay its last claimant, with no bound on how far short it fell.

The fix is to carry the raw modulus in **scaled** units (`scaled % supply`). Every deposit is then exact to within the single final truncation in `accumulated`, so the per-holder shortfall is pinned at one wei and, critically, always points the same way: the contract holds slightly more than it owes, never less.

This is why payout assertions in this suite use a deliberately one-sided helper (`_assertOwed`) rather than exact equality. Rounding down is not an imprecision the tests tolerate, it is the mechanism that keeps the contract solvent — an exact-equality assertion would be asserting a rounding direction the design explicitly does not promise, and would fail the moment the split is not clean.

---

## Forced recovery

| Test | Asserts |
| :--- | :------ |
| [`test_recovery_carriesEntitlementToTheNewWallet`](../../test/unit/DividendDistributor.t.sol#L384) | **Recovery relocates the position whole: unclaimed income follows the balance** |
| [`test_recovery_lostWalletCannotClaimAfterwards`](../../test/unit/DividendDistributor.t.sol#L401) | The compromised wallet is left owed exactly nothing |
| [`test_recovery_carriesTheWithdrawalRecord`](../../test/unit/DividendDistributor.t.sol#L416) | The `withdrawn` record moves too, so recovery cannot re-open a settled claim |
| [`test_recovery_newWalletAccruesFutureIncome`](../../test/unit/DividendDistributor.t.sol#L434) | The recovered wallet accrues normally afterwards, as the position's only owner |

**The second bug, and the more serious one.** Settling a recovery like an ordinary sale leaves the unclaimed income on the lost wallet — precisely the wallet the investor no longer controls. This was verified end to end before it was fixed: after a successful `forcedRecovery`, the compromised address still drained the full deposit. The tokens were rescued and the money was not.

The accumulator cannot distinguish the two cases on its own, because `moduleTransferred(from, to, amount)` is byte-identical for a sale and a recovery while the two mean opposite things for anything that accrues value. `SecurityToken` therefore exposes a `recovering()` view over its existing internal flag, and the hook branches on it. Carrying `withdrawn` alongside `correction` matters as much as the correction itself: without it the new wallet could re-claim income the old one had already been legitimately paid.

This is the one place the distributor depends on the token being a `SecurityToken` rather than any ERC-20, and it is a real seam in the module abstraction — see [Trade-offs](../04-tradeoffs.md).

---

## Module surface

| Test | Asserts |
| :--- | :------ |
| [`test_moduleCheck_alwaysPermits`](../../test/unit/DividendDistributor.t.sol#L452) | **The distributor never blocks a transfer**, for any argument shape including mints and burns |
| [`test_moduleTransferred_revertsForNonCompliance`](../../test/unit/DividendDistributor.t.sol#L463) | Only the bound engine may drive `moduleTransferred` |
| [`test_moduleCreated_revertsForNonCompliance`](../../test/unit/DividendDistributor.t.sol#L469) | Only the bound engine may drive `moduleCreated` |
| [`test_moduleDestroyed_revertsForNonCompliance`](../../test/unit/DividendDistributor.t.sol#L475) | Only the bound engine may drive `moduleDestroyed` |

`moduleCheck` returning an unconditional `true` is a design statement, not a stub: the distributor is an observer that keeps accounts, not a rule that expresses a restriction. Withholding income from a sanctioned holder is a matter for the token's freeze controls, not for the transfer gate. The test pins that so a future change cannot quietly turn income accounting into a transfer restriction.

The hook gating is not ceremonial here. An ungated `moduleTransferred` would let anyone shift corrections between accounts and mint themselves an arbitrary entitlement against real deposited funds.

---

## Fuzz

| Test | Property |
| :--- | :------- |
| [`testFuzz_conservation_claimsNeverExceedDeposits`](../../test/unit/DividendDistributor.t.sol#L515) | Across arbitrary balances and deposit sizes, total entitlement never exceeds the amount deposited |
| [`testFuzz_roundingDustIsBounded`](../../test/unit/DividendDistributor.t.sol#L533) | The shortfall is at most one wei per holder, not an unbounded leak |
| [`testFuzz_transferPreservesTotalEntitlement`](../../test/unit/DividendDistributor.t.sol#L549) | A transfer of any size leaves the sum of entitlements exactly unchanged |
| [`testFuzz_solventAcrossRepeatedDeposits`](../../test/unit/DividendDistributor.t.sol#L567) | **Over up to twenty deposits, the contract always holds at least what it says is owed** |
| [`testFuzz_claimIsAlwaysSolvent`](../../test/unit/DividendDistributor.t.sol#L588) | Every claim the contract reports as owed can actually be paid out |

`testFuzz_solventAcrossRepeatedDeposits` is the one that would have caught the compounding-residue bug, and it is deliberately multi-deposit: the single-deposit properties all passed while the contract was insolvent, because the error only appears once a second deposit is folded in. Depth, not breadth, was what mattered.

The whole group is run at 20,000 runs before the unit is trusted, matching the practice established for the [invariant suite](./11-invariants.md). The default run count is not evidence for arithmetic this sensitive to rounding.

---

## Integration

The unit suite drives the hooks from a mocked engine address, which proves the arithmetic but not the wiring. These run against the system `Deploy` produces, with the real engine, registry, token and all three rule modules.

| Test | Asserts |
| :--- | :------ |
| [`test_scenario_incomeAccruesToTheHolderAtTheTimeOfDeposit`](../../test/scenario/Dividends.t.sol#L69) | The full cycle: subscribe, receive income, sell after the lockup, and see entitlement split at the moment of sale |
| [`test_scenario_recoveryCarriesUnclaimedIncome`](../../test/scenario/Dividends.t.sol#L106) | **Through the real `forcedRecovery`**, income follows the position to the new wallet |
| [`test_scenario_distributorDoesNotGateTransfers`](../../test/scenario/Dividends.t.sol#L132) | Registering the distributor does not turn it into a transfer restriction |
| [`test_scenario_multiHolderDistributionStaysSolvent`](../../test/scenario/Dividends.t.sol#L151) | Five deposits across a real holder set stay within the funds received |

The suite registers the distributor with `addModule` **after** `_deploy` has already closed the graph. That is the point rather than a convenience: it demonstrates that a new capability is added to a live system without redeploying anything and without touching the token, which is the claim the module architecture makes. `removeModule` reverses it just as cleanly.

---

## Infrastructure

Two mocks are specific to this suite:

- [`MockCurrency`](../../test/helpers/MockCurrency.sol) is deliberately **6-decimal**, matching a real stablecoin rather than the 18-decimal token. A distributor tested only against an 18-decimal currency hides precision bugs that appear when the settlement currency is far coarser than the security token, which is exactly the real configuration.
- `MockRecoverableToken` extends the shared [`MockToken`](../../test/helpers/MockToken.sol) with a settable `recovering` flag, so the recovery branch is reachable in unit tests. The shared mock was **not** modified, because the other module suites depend on it and widening it would couple them to a token feature they have no interest in.

---

## 📚 References

- [Testing index](./README.md)
- [Guide 2: Mathematics §8](../02-mathematics.md#8-dividend-accrual-without-enumeration) — the accumulator, the correction, and why recovery needs its own branch
- [Max Holders Module](./05-max-holders-module.md) — the self-transfer inference bug this module deliberately avoids repeating
- [Security Token](./07-security-token.md) — the `_update` branches, including the recovery path these hooks observe
- [Invariant Suite](./11-invariants.md) — the high-effort run practice applied to this unit's fuzz group
- [Guide 6: Improvements](../06-improvements.md#6-dividend-distribution-the-planned-stretch-unit) — the design as originally specified
