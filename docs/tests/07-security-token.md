# Security Token (Phase 4)

**Suites:** [`SecurityTokenTest`](../../test/unit/SecurityToken.t.sol) (56 unit + 3 fuzz)
**Covers:** roadmap items 4.1 to 4.7 · [Guide 3, the transfer gate](../03-architecture.md#4-the-transfer-gate-a-superset-check) · [Guide 4, recovery blast radius](../04-tradeoffs.md)

---

> The centrepiece, and the largest suite. An ERC-20 in shape whose every movement is gated by identity and compliance, plus the issuer powers a regulated instrument requires. Two themes run through the tests: the gate must be impossible to route around, and the powerful operations — burn, freeze, recovery — are tested mostly by what they **cannot** do. Where a mechanism stops tokens moving, there is always a paired test proving the balance survives, because a compliance control that quietly destroys value is a worse failure than one that blocks too much.

## Constructor

| Test | Asserts |
| :--- | :------ |
| [`test_constructor_setsState`](../../test/unit/SecurityToken.t.sol#L88) | Name, symbol, registry, engine and the issuer's admin role are all set |
| [`test_constructor_revertsOnZeroIssuer`](../../test/unit/SecurityToken.t.sol#L96) | A zero issuer is refused |
| [`test_constructor_revertsOnZeroRegistry`](../../test/unit/SecurityToken.t.sol#L101) | A zero registry is refused: without it, no transfer could ever be checked |
| [`test_constructor_revertsOnZeroCompliance`](../../test/unit/SecurityToken.t.sol#L106) | A zero engine is refused |

---

## Mint (4.6)

| Test | Asserts |
| :--- | :------ |
| [`test_mint_creditsVerifiedRecipient`](../../test/unit/SecurityToken.t.sol#L115) | Issuance credits the subscriber and raises total supply |
| [`test_mint_firesCreatedHook`](../../test/unit/SecurityToken.t.sol#L122) | The engine's `created` hook fires, so stateful modules record the new position |
| [`test_mint_revertsForNonIssuer`](../../test/unit/SecurityToken.t.sol#L130) | Only `DEFAULT_ADMIN_ROLE` may mint: supply is the issuer's, not the agent's |
| [`test_mint_revertsForUnverifiedRecipient`](../../test/unit/SecurityToken.t.sol#L141) | **A mint clears the same identity gate a transfer does.** Primary issuance is not a back door into an unverified wallet |
| [`test_mint_revertsWhenComplianceRejects`](../../test/unit/SecurityToken.t.sol#L147) | A module rejecting blocks the mint, so the holder cap applies to issuance too |

---

## Burn (4.6)

| Test | Asserts |
| :--- | :------ |
| [`test_burn_reducesBalanceAndSupply`](../../test/unit/SecurityToken.t.sol#L159) | Retiring a position reduces both the balance and total supply |
| [`test_burn_firesDestroyedHook`](../../test/unit/SecurityToken.t.sol#L169) | The engine's `destroyed` hook fires so the holder count can fall |
| [`test_burn_revertsForNonIssuer`](../../test/unit/SecurityToken.t.sol#L178) | Only the issuer may burn |
| [`test_burn_belowFreeLeavesFrozenIntact`](../../test/unit/SecurityToken.t.sol#L190) | A burn within the free balance does not touch the frozen portion |
| [`test_burn_eatsFrozenWhenExceedingFree`](../../test/unit/SecurityToken.t.sol#L204) | **A burn larger than the free balance reduces the frozen portion to cover the shortfall**, emitting `TokensUnfrozen` for the amount released |

The last pair encodes a deliberate ordering of authority: **the issuer outranks an operational freeze.** A freeze is a compliance hold placed by an agent; a burn is the issuer retiring a position, which in practice follows a redemption, a court order, or a corporate action. If a freeze could shelter tokens from a burn, an agent could unilaterally block the issuer from discharging a legal obligation. Reconciling the frozen figure downward also preserves the `frozen <= balance` invariant, which would otherwise break the moment a burn cut the balance below the frozen amount.

---

## Freeze controls (4.4)

| Test | Asserts |
| :--- | :------ |
| [`test_setAddressFrozen_togglesAndEmits`](../../test/unit/SecurityToken.t.sol#L223) | A full freeze can be set and cleared, emitting `AddressFrozen` both ways |
| [`test_setAddressFrozen_revertsForNonAgent`](../../test/unit/SecurityToken.t.sol#L236) | Freezing is agent-gated |
| [`test_freezePartialTokens_accumulatesAndEmits`](../../test/unit/SecurityToken.t.sol#L244) | Partial freezes accumulate rather than overwrite, so two holds coexist |
| [`test_freezePartialTokens_revertsAboveBalance`](../../test/unit/SecurityToken.t.sol#L259) | **Frozen can never exceed the balance**, which would underflow the unfrozen calculation in the gate |
| [`test_unfreezePartialTokens_reducesAndEmits`](../../test/unit/SecurityToken.t.sol#L268) | Releasing reduces the frozen figure and emits |
| [`test_unfreezePartialTokens_revertsAboveFrozen`](../../test/unit/SecurityToken.t.sol#L281) | Releasing more than is held reverts rather than wrapping to a huge number |

Both bounds exist to keep `frozenTokens[a] <= balanceOf(a)` true by construction. The gate computes the movable amount as `balance - frozen`; if `frozen` could exceed `balance`, that subtraction reverts on underflow and the wallet becomes permanently unable to transact, which is a lock nobody chose and nobody can clear.

---

## The transfer gate (4.2, 4.3)

One internal status-code function is shared by `_update` (which reverts) and `canTransfer` (which returns a bool), so the answer a front end reads cannot drift from what a transfer enforces.

| Test | Asserts |
| :--- | :------ |
| [`test_transfer_succeedsBetweenVerified`](../../test/unit/SecurityToken.t.sol#L297) | The happy path moves balances and fires `transferred` |
| [`test_transfer_revertsForUnverifiedRecipient`](../../test/unit/SecurityToken.t.sol#L308) | An unverified recipient is refused, naming the address |
| [`test_transfer_revertsForUnverifiedSender`](../../test/unit/SecurityToken.t.sol#L320) | **An unverified sender is refused too**: withdrawing an identity immobilises the position rather than only capping it |
| [`test_transfer_unverifiedSenderKeepsBalance`](../../test/unit/SecurityToken.t.sol#L332) | The suspended balance is untouched: losing an attestation does not extinguish title |
| [`test_transfer_resumesAfterReverification`](../../test/unit/SecurityToken.t.sol#L342) | Re-verifying releases the position, so the measure is reversible |
| [`test_transfer_revertsWhenRecipientFrozen`](../../test/unit/SecurityToken.t.sol#L354) | A frozen recipient cannot receive |
| [`test_transfer_revertsWhenSenderFrozen`](../../test/unit/SecurityToken.t.sol#L364) | A frozen sender cannot send |
| [`test_transfer_revertsWhenExceedingUnfrozen`](../../test/unit/SecurityToken.t.sol#L374) | A transfer above the unfrozen portion reverts, reporting available and required |
| [`test_transfer_movesUnfrozenPortion`](../../test/unit/SecurityToken.t.sol#L389) | The unfrozen portion still moves freely, so a partial hold is partial |
| [`test_transfer_revertsWhenComplianceRejects`](../../test/unit/SecurityToken.t.sol#L401) | A module rejecting blocks the transfer |

**Identity is checked on both ends.** The sender-side check exists because `removeIdentity` is what compliance reaches for when an investor may no longer hold the instrument at all — a sanction, a lapsed jurisdiction, a failed re-screening. A gate that only blocked *incoming* transfers would leave the sanctioned party free to sell their entire position, which makes the measure decorative. The three tests above form a set: the position cannot move, it is not confiscated, and compliance can undo the suspension. That is what distinguishes a suspension from a seizure, and it is why the invariant in the [coverage map](./README.md#-invariant-coverage-map) is phrased as "no unverified address can *increase* its balance" rather than "no unverified holder exists".

---

## Pause, and the recovery exemption (4.4)

| Test | Asserts |
| :--- | :------ |
| [`test_pause_haltsTransfers`](../../test/unit/SecurityToken.t.sol#L414) | A pause stops ordinary transfers |
| [`test_pause_haltsMintAndBurn`](../../test/unit/SecurityToken.t.sol#L425) | It stops issuance and retirement too: pause is a market-wide stop, not a trading-only one |
| [`test_unpause_resumesTransfers`](../../test/unit/SecurityToken.t.sol#L433) | Unpausing restores normal operation |
| [`test_pause_revertsForNonAgent`](../../test/unit/SecurityToken.t.sol#L506) | Pausing is agent-gated |
| [`test_pause_doesNotBlockForcedRecovery`](../../test/unit/SecurityToken.t.sol#L447) | **Recovery works while paused**, and the token stays paused afterwards |
| [`test_pause_recoveryExemptionDoesNotOutliveTheCall`](../../test/unit/SecurityToken.t.sol#L462) | After the recovery returns, the pause is back in force for everyone — including the wallet that just received the position |
| [`test_pause_recoveryStillRequiresCustodian`](../../test/unit/SecurityToken.t.sol#L479) | The exemption does not widen *who* may recover |
| [`test_pause_recoveryStillEnforcesIdentityCheck`](../../test/unit/SecurityToken.t.sol#L494) | Nor does it relax recovery's own investor check |

A pause is usually the response to the very incident recovery exists to resolve, so halting trading must not also strand the compromised position. The exemption is implemented as a transient `_recovering` flag set only inside `forcedRecovery`, and the last three tests are what make that narrow rather than a hole: it does not persist past the call, it does not grant the power to anyone new, and it does not disable the checks recovery performs itself.

---

## The `canTransfer` view

| Test | Asserts |
| :--- | :------ |
| [`test_canTransfer_trueForValidTransfer`](../../test/unit/SecurityToken.t.sol#L518) | True when a transfer would succeed |
| [`test_canTransfer_falseForUnverifiedRecipient`](../../test/unit/SecurityToken.t.sol#L523) | False when identity would reject |
| [`test_canTransfer_falseWhenPaused`](../../test/unit/SecurityToken.t.sol#L528) | False while paused, matching `_update` |
| [`test_canTransfer_agreesWithUpdate`](../../test/unit/SecurityToken.t.sol#L537) | **The view and the enforcement agree** across a range of states |

The last test is the one that justifies the shared status-code design. A front end that pre-checks with `canTransfer` and then submits a transfer must not be told "yes" and then reverted; the two paths call the same internal function precisely so they cannot disagree, and this test asserts the property rather than trusting the structure.

---

## Forced recovery (4.5)

The most powerful operation in the system: it moves an arbitrary balance between wallets. Most of its tests are therefore negative.

### What it does

| Test | Asserts |
| :--- | :------ |
| [`test_forcedRecovery_movesFullBalance`](../../test/unit/SecurityToken.t.sol#L555) | The whole position relocates and **total supply is unchanged**: recovery is a reassignment, never issuance |
| [`test_forcedRecovery_retiresLostWallet`](../../test/unit/SecurityToken.t.sol#L567) | The compromised wallet is evicted from the registry, so it can never hold again |
| [`test_forcedRecovery_emitsSuccess`](../../test/unit/SecurityToken.t.sol#L605) | `RecoverySuccess` names both wallets, the amount, and the carried freeze state |

### What it cannot do

| Test | Asserts |
| :--- | :------ |
| [`test_forcedRecovery_revertsForNonCustodian`](../../test/unit/SecurityToken.t.sol#L617) | Only `CUSTODIAN_ROLE`, so the compliance desk cannot seize a position |
| [`test_forcedRecovery_revertsAcrossInvestors`](../../test/unit/SecurityToken.t.sol#L675) | **A verified destination is not enough**: both wallets must share an `investorId` |
| [`test_forcedRecovery_revertsForUnverifiedNewWallet`](../../test/unit/SecurityToken.t.sol#L628) | The destination must be verified |
| [`test_forcedRecovery_revertsForEmptyWallet`](../../test/unit/SecurityToken.t.sol#L637) | Recovering nothing reverts rather than emitting a misleading success |
| [`test_forcedRecovery_revertsForSameWallet`](../../test/unit/SecurityToken.t.sol#L723) | Recovering into the same wallet is refused |

The investor check is the difference between recovery and confiscation. Without it, a custodian could move any balance to any verified wallet — including one they control as an onboarded investor — and the operation would look identical on-chain to a legitimate recovery. Requiring a shared `investorId` means the destination must be another wallet of the *same person*, which is the ERC-3643 property of proving the new wallet is a management key of the investor's ONCHAINID. The residual risk, where a custodian key and an agent key collude to link an attacker wallet first, is stated in the [threat model](../../README.md#threat-model).

### The freeze travels

| Test | Asserts |
| :--- | :------ |
| [`test_forcedRecovery_carriesPartialFreeze`](../../test/unit/SecurityToken.t.sol#L578) | A partial hold moves to the new wallet and is cleared on the old one |
| [`test_forcedRecovery_carriesFullFreeze`](../../test/unit/SecurityToken.t.sol#L592) | A full freeze is re-applied at the destination; the lost wallet must be unfrozen internally first, or its own freeze would block the move |
| [`test_forcedRecovery_partialFreezeLeavesExistingBalanceUnfrozen`](../../test/unit/SecurityToken.t.sol#L687) | A partial freeze is **additive**: tokens already at the destination keep their own frozen/unfrozen split |
| [`test_forcedRecovery_fullFreezeCoversPreExistingBalance`](../../test/unit/SecurityToken.t.sol#L705) | A full freeze **covers the whole destination**, including tokens already there |

Recovery relocates a position; it does not launder a hold. The asymmetry in the last two is deliberate and worth stating: a partial freeze is a property of a *lot*, so it moves with the tokens it applies to, while a full freeze is a property of the *investor*, so it applies to everything they hold at the destination. The identity check guarantees the destination belongs to the same investor, which is what makes the second behaviour correct rather than collateral damage.

### The gate is bypassed

| Test | Asserts |
| :--- | :------ |
| [`test_forcedRecovery_succeedsWhenComplianceRejects`](../../test/unit/SecurityToken.t.sol#L646) | A module rejecting does not block recovery: an unexpired lockup cannot strand a compromised position |
| [`test_forcedRecovery_succeedsIntoFrozenWallet`](../../test/unit/SecurityToken.t.sol#L661) | A frozen destination does not block it either |

Recovery skips the transfer gate entirely rather than relaxing it, for the same reason it skips the pause. Every check the gate performs is either already guaranteed by `forcedRecovery` itself (destination verified, same investor, sender's freeze cleared, exact balance) or is the wrong question to ask during an incident. The frozen-destination case is the sharper of the two: without the bypass, the operation would refuse to proceed because of a state it re-applies moments later.

---

## Fuzz

| Test | Property |
| :--- | :------- |
| [`testFuzz_transferConservesSupply`](../../test/unit/SecurityToken.t.sol#L735) | For any transfer amount, total supply is unchanged |
| [`testFuzz_recoveryConservesSupply`](../../test/unit/SecurityToken.t.sol#L748) | For any balance and freeze configuration, recovery conserves supply |
| [`testFuzz_cannotMoveFrozenPortion`](../../test/unit/SecurityToken.t.sol#L772) | For any freeze/transfer split, exactly the unfrozen portion is movable and no more |

Supply conservation under recovery is the property most worth fuzzing: recovery touches balances, freeze state and the registry in one call, and an error in the ordering would show up as tokens created or destroyed. Asserting it across arbitrary configurations is the strongest statement available before the [handler suite](./12-gaps-and-roadmap.md) makes it hold across arbitrary *sequences*.
