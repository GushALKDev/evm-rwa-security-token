# Security Token (Phase 4)

**Suites:** [`SecurityTokenTest`](../../test/unit/SecurityToken.t.sol) (61 unit + 3 fuzz)
**Covers:** roadmap items 4.1 to 4.7 · [Guide 3, the transfer gate](../03-architecture.md#4-the-transfer-gate-a-superset-check) · [Guide 4, recovery blast radius](../04-tradeoffs.md)

---

> The centrepiece, and the largest suite. An ERC-20 in shape whose every movement is gated by identity and compliance, plus the issuer powers a regulated instrument requires. Two themes run through the tests: the gate must not be routable around, and the powerful operations (burn, freeze, recovery) are tested mostly by what they **cannot** do. Where a mechanism stops tokens moving, there is a paired test showing the balance survives, because a compliance control that quietly destroys value is a worse failure than one that blocks too much.

The suite wires a real `IdentityRegistry` and `ModularCompliance` with one [`MockModule`](../../test/helpers/MockModule.sol) whose verdict the test toggles. `alice` and `aliceSecondary` share an `investorId`, which makes `aliceSecondary` the only valid recovery destination for `alice`.

## Constructor

| Test | Asserts |
| :--- | :------ |
| [`test_constructor_setsState`](../../test/unit/SecurityToken.t.sol#L90) | Name, symbol, registry, engine and the issuer's admin role are all set |
| [`test_constructor_revertsOnZeroIssuer`](../../test/unit/SecurityToken.t.sol#L98) | A zero issuer reverts `ZeroAddress` |
| [`test_constructor_revertsOnZeroRegistry`](../../test/unit/SecurityToken.t.sol#L103) | A zero registry reverts `ZeroAddress`: without it, no transfer could be checked |
| [`test_constructor_revertsOnZeroCompliance`](../../test/unit/SecurityToken.t.sol#L108) | A zero engine reverts `ZeroAddress` |

---

## Mint (4.6)

| Test | Asserts |
| :--- | :------ |
| [`test_mint_creditsVerifiedRecipient`](../../test/unit/SecurityToken.t.sol#L117) | Issuance credits the subscriber and raises total supply |
| [`test_mint_firesCreatedHook`](../../test/unit/SecurityToken.t.sol#L124) | The module's `moduleCreated` hook fires once with the recipient and amount |
| [`test_mint_revertsForNonIssuer`](../../test/unit/SecurityToken.t.sol#L132) | Only `DEFAULT_ADMIN_ROLE` may mint: supply is the issuer's, not the agent's |
| [`test_mint_revertsForUnverifiedRecipient`](../../test/unit/SecurityToken.t.sol#L143) | **A mint clears the same identity gate a transfer does** (`RecipientNotVerified`). Primary issuance is not a back door into an unverified wallet |
| [`test_mint_revertsWhenComplianceRejects`](../../test/unit/SecurityToken.t.sol#L149) | A module rejecting blocks the mint with `ComplianceCheckFailed(0, to, amount)`, so rules such as the holder cap apply to issuance too |

---

## Burn (4.6)

| Test | Asserts |
| :--- | :------ |
| [`test_burn_reducesBalanceAndSupply`](../../test/unit/SecurityToken.t.sol#L161) | Retiring a quarter of a position reduces both the balance and total supply by that amount |
| [`test_burn_firesDestroyedHook`](../../test/unit/SecurityToken.t.sol#L171) | The module's `moduleDestroyed` hook fires once |
| [`test_burn_revertsForNonIssuer`](../../test/unit/SecurityToken.t.sol#L180) | Only the issuer may burn |
| [`test_burn_belowFreeLeavesFrozenIntact`](../../test/unit/SecurityToken.t.sol#L192) | A burn within the free balance leaves the frozen figure unchanged |
| [`test_burn_eatsFrozenWhenExceedingFree`](../../test/unit/SecurityToken.t.sol#L206) | **A burn larger than the free balance reduces the frozen portion to cover the shortfall**, emitting `TokensUnfrozen` for the amount released |

The last pair encodes a deliberate ordering of authority: **the issuer outranks an operational freeze.** A freeze is a compliance hold placed by an agent; a burn is the issuer retiring a position, which in practice follows a redemption, a court order, or a corporate action. Reconciling the frozen figure downward also preserves `frozen <= balance`, which would otherwise break the moment a burn cut the balance below the frozen amount.

A burn larger than the whole balance of a wallet with frozen tokens used to hit that arithmetic first and panic (review finding 8). The regression, [`test_burn_aboveBalance_revertsWithInsufficientBalance`](../../test/scenario/Regressions.t.sol#L511), asserts the ERC-20 `ERC20InsufficientBalance` error instead.

---

## Freeze controls (4.4)

| Test | Asserts |
| :--- | :------ |
| [`test_setAddressFrozen_togglesAndEmits`](../../test/unit/SecurityToken.t.sol#L225) | A full freeze is set, emitting `AddressFrozen(true)`, and cleared, with `isFrozen` following both ways |
| [`test_setAddressFrozen_revertsForNonAgent`](../../test/unit/SecurityToken.t.sol#L238) | Freezing is agent-gated |
| [`test_freezePartialTokens_accumulatesAndEmits`](../../test/unit/SecurityToken.t.sol#L246) | Two partial freezes of a quarter each add up to half, with `TokensFrozen` on the first: holds accumulate rather than overwrite |
| [`test_freezePartialTokens_revertsAboveBalance`](../../test/unit/SecurityToken.t.sol#L261) | **Frozen can never exceed the balance**: `FreezeAmountExceedsBalance(investor, balance, requested)` |
| [`test_unfreezePartialTokens_reducesAndEmits`](../../test/unit/SecurityToken.t.sol#L270) | Releasing reduces the frozen figure and emits `TokensUnfrozen` |
| [`test_unfreezePartialTokens_revertsAboveFrozen`](../../test/unit/SecurityToken.t.sol#L283) | Releasing more than is held reverts `UnfreezeAmountExceedsFrozen` rather than wrapping |

Both bounds exist to keep `frozenTokens[a] <= balanceOf(a)` true by construction. The gate computes the movable amount as `balance - frozen`; if `frozen` could exceed `balance`, that subtraction would underflow and the wallet could not transact until someone noticed. The stateful form is [`invariant_frozenNeverExceedsBalance`](../../test/invariant/Invariants.t.sol#L151).

---

## The transfer gate (4.2, 4.3)

One internal status-code function is shared by `_update` (which reverts) and `canTransfer` (which returns a bool), so the answer a front end reads cannot drift from what a transfer enforces.

| Test | Asserts |
| :--- | :------ |
| [`test_transfer_succeedsBetweenVerified`](../../test/unit/SecurityToken.t.sol#L299) | The happy path moves balances and fires `moduleTransferred` once |
| [`test_transfer_revertsForUnverifiedRecipient`](../../test/unit/SecurityToken.t.sol#L310) | An unverified recipient reverts `RecipientNotVerified`, naming the address |
| [`test_transfer_revertsForUnverifiedSender`](../../test/unit/SecurityToken.t.sol#L322) | **An unverified sender is refused too** (`SenderNotVerified`): withdrawing an identity immobilises the position rather than only capping it |
| [`test_transfer_unverifiedSenderKeepsBalance`](../../test/unit/SecurityToken.t.sol#L334) | After `removeIdentity`, balance and supply are unchanged: losing an attestation does not extinguish title |
| [`test_transfer_resumesAfterReverification`](../../test/unit/SecurityToken.t.sol#L344) | Re-verifying releases the position, so the measure is reversible |
| [`test_transfer_revertsWhenRecipientFrozen`](../../test/unit/SecurityToken.t.sol#L356) | A frozen recipient reverts `RecipientAddressFrozen` |
| [`test_transfer_revertsWhenSenderFrozen`](../../test/unit/SecurityToken.t.sol#L366) | A frozen sender reverts `SenderAddressFrozen` |
| [`test_transfer_revertsWhenExceedingUnfrozen`](../../test/unit/SecurityToken.t.sol#L376) | One wei above the unfrozen portion reverts `InsufficientUnfrozenBalance(from, available, required)` |
| [`test_transfer_movesUnfrozenPortion`](../../test/unit/SecurityToken.t.sol#L391) | The unfrozen half still moves, and the frozen half stays frozen: a partial hold is partial |
| [`test_transfer_revertsWhenComplianceRejects`](../../test/unit/SecurityToken.t.sol#L403) | A module rejecting reverts `ComplianceCheckFailed(from, to, amount)` |

**Identity is checked on both ends.** The sender-side check exists because `removeIdentity` is what compliance reaches for when an investor may no longer hold the instrument at all: a sanction, a lapsed jurisdiction, a failed re-screening. A gate that only blocked *incoming* transfers would leave the sanctioned party free to sell their entire position. The three tests above form a set: the position cannot move, it is not confiscated, and compliance can undo the suspension. That is what distinguishes a suspension from a seizure, and it is why the invariant in the [coverage map](./README.md#invariant-coverage-map) is phrased as "no unverified address can *increase* its balance" rather than "no unverified holder exists".

---

## `transferFrom`

| Test | Asserts |
| :--- | :------ |
| [`test_transferFrom_consumesAllowance`](../../test/unit/SecurityToken.t.sol#L592) | A spender moves 100 of a 300 allowance, the allowance drops to 200, and spending 300 more reverts `ERC20InsufficientAllowance` |
| [`test_transferFrom_revertsForFrozenSender`](../../test/unit/SecurityToken.t.sol#L609) | The gate applies to `transferFrom` as to `transfer`: spending from a frozen owner reverts `SenderAddressFrozen` |
| [`test_transferFrom_revertsForUnverifiedRecipient`](../../test/unit/SecurityToken.t.sol#L622) | Whoever the spender is, an unverified recipient reverts `RecipientNotVerified` |
| [`test_transferFrom_spenderIsNotChecked`](../../test/unit/SecurityToken.t.sol#L638) | **Documented limitation.** An unverified spender and a frozen spender both move tokens between two verified, unfrozen holders within their allowance |

The last test pins a limitation rather than a protection: the gate checks the two holders, not the caller, and ERC-3643 behaves the same way. Its comment says that if it starts failing, the limitation was closed and the documentation must change with it. The invariant handler uses an unregistered outsider as `transferFrom` spender for the same reason, see [the handler](./11-invariants.md#the-handler).

---

## Pause, and the recovery exemption (4.4)

| Test | Asserts |
| :--- | :------ |
| [`test_pause_haltsTransfers`](../../test/unit/SecurityToken.t.sol#L416) | A pause makes a transfer revert `EnforcedPause` |
| [`test_pause_haltsMintAndBurn`](../../test/unit/SecurityToken.t.sol#L427) | A pause makes a mint revert `EnforcedPause`. Despite the name, only the mint is asserted here; the burn under pause is asserted in [`test_pause_againstEachRoleAction`](../../test/scenario/EdgeCases.t.sol#L289) |
| [`test_unpause_resumesTransfers`](../../test/unit/SecurityToken.t.sol#L435) | Unpausing restores normal operation |
| [`test_pause_revertsForNonAgent`](../../test/unit/SecurityToken.t.sol#L508) | Pausing is agent-gated |
| [`test_pause_doesNotBlockForcedRecovery`](../../test/unit/SecurityToken.t.sol#L449) | **Recovery works while paused**, and the token stays paused afterwards |
| [`test_pause_recoveryExemptionDoesNotOutliveTheCall`](../../test/unit/SecurityToken.t.sol#L464) | After the recovery returns, the wallet that just received the position cannot transfer and the issuer cannot mint: both revert `EnforcedPause` |
| [`test_pause_recoveryStillRequiresCustodian`](../../test/unit/SecurityToken.t.sol#L481) | While paused, a non-custodian calling recovery reverts `AccessControlUnauthorizedAccount` with `CUSTODIAN_ROLE` |
| [`test_pause_recoveryStillEnforcesIdentityCheck`](../../test/unit/SecurityToken.t.sol#L496) | While paused, recovering into another investor's wallet reverts `RecoveryAcrossInvestors` |

A pause is usually the response to the very incident recovery exists to resolve, so halting trading must not also strand the compromised position. The exemption is a `_recovering` flag set only inside `forcedRecovery`, and the last three tests are what keep it narrow: it does not persist past the call, it does not grant the power to anyone new, and it does not disable the checks recovery performs itself.

---

## The `canTransfer` view

| Test | Asserts |
| :--- | :------ |
| [`test_canTransfer_trueForValidTransfer`](../../test/unit/SecurityToken.t.sol#L520) | True when a transfer would succeed |
| [`test_canTransfer_falseForUnverifiedRecipient`](../../test/unit/SecurityToken.t.sol#L525) | False for an unverified recipient |
| [`test_canTransfer_falseWhenPaused`](../../test/unit/SecurityToken.t.sol#L530) | False while paused, matching `_update` |
| [`test_canTransfer_agreesWithUpdate`](../../test/unit/SecurityToken.t.sol#L569) | **The view and the enforcement agree** across nine gate states, each from a snapshot: clean, paused, recipient unverified, sender unverified, recipient frozen, sender frozen, amount above the unfrozen balance, module rejecting, and both attestations expired. In each, the view's answer equals whether the transfer settled, and only the clean state settles |

The last test is the one that justifies the shared status-code design. A front end that pre-checks with `canTransfer` and then submits a transfer must not be told "yes" and then reverted. The test drives every check the gate performs and compares the view with the real call, rather than trusting the shared code path.

---

## Forced recovery (4.5)

The most powerful operation in the system: it moves an arbitrary balance between wallets. Most of its tests are therefore negative.

### What it does

| Test | Asserts |
| :--- | :------ |
| [`test_forcedRecovery_movesFullBalance`](../../test/unit/SecurityToken.t.sol#L660) | The whole position relocates and **total supply is unchanged**: recovery is a reassignment, never issuance |
| [`test_forcedRecovery_retiresLostWallet`](../../test/unit/SecurityToken.t.sol#L672) | The lost wallet is no longer verified after the recovery |
| [`test_forcedRecovery_emitsSuccess`](../../test/unit/SecurityToken.t.sol#L710) | `RecoverySuccess` names both wallets, the amount, the carried partial freeze and the full-freeze flag |

Recovery evicts the lost wallet by calling `removeIdentity`, so it can no longer send or receive. The eviction is not permanent: an agent can register the wallet again. What a retired wallet can and cannot do afterwards is walked in [`test_scenario_retiredWalletCannotBeUsedAgain`](../../test/scenario/Lifecycle.t.sol#L189) and [`test_recoveredLostWallet_cannotClaim`](../../test/scenario/EdgeCases.t.sol#L183).

### What it cannot do

| Test | Asserts |
| :--- | :------ |
| [`test_forcedRecovery_revertsForNonCustodian`](../../test/unit/SecurityToken.t.sol#L722) | Only `CUSTODIAN_ROLE` may recover |
| [`test_forcedRecovery_revertsAcrossInvestors`](../../test/unit/SecurityToken.t.sol#L780) | **A verified destination is not enough**: into a verified wallet of another investor, it reverts `RecoveryAcrossInvestors(lostId, newId)` |
| [`test_forcedRecovery_revertsForUnverifiedNewWallet`](../../test/unit/SecurityToken.t.sol#L733) | An unverified destination reverts `NewWalletNotVerified` |
| [`test_forcedRecovery_revertsForEmptyWallet`](../../test/unit/SecurityToken.t.sol#L742) | Recovering an empty wallet reverts `NothingToRecover` rather than emitting a misleading success |
| [`test_forcedRecovery_revertsForSameWallet`](../../test/unit/SecurityToken.t.sol#L859) | Recovering into the same wallet reverts `RecoveryToSameWallet` |
| [`test_forcedRecovery_isReentrancyGuarded`](../../test/unit/SecurityToken.t.sol#L835) | A registered module holding `CUSTODIAN_ROLE` reenters `forcedRecovery` from the recovery's own transfer hook: the module records that it tried, the reentry fails with `ReentrancyGuardReentrantCall`, the outer recovery completes with the partial freeze carried, and the target of the reentrant call keeps its balance |

The investor check is the difference between recovery and confiscation. Without it, a custodian could move any balance to any verified wallet (including one they control as an onboarded investor), and the operation would look identical on-chain to a legitimate recovery. The residual risk, where a custodian key and an agent key collude to link an attacker wallet first, is stated in the [threat model](../../README.md#threat-model).

The reentrancy test targets the one window where the freeze has been cleared on the lost wallet and not yet re-applied on the new one. The module is given the custodian role so that only the guard can stop it.

A wallet the agent had already suspended used to be unrecoverable (review finding 3), because removal deleted the `investorId` that the check above compares. The regression is [`test_forcedRecovery_succeedsAfterAgentRemovedLostWallet`](../../test/scenario/Regressions.t.sol#L218).

### The freeze travels

| Test | Asserts |
| :--- | :------ |
| [`test_forcedRecovery_carriesPartialFreeze`](../../test/unit/SecurityToken.t.sol#L683) | A partial hold moves to the new wallet and is cleared on the old one |
| [`test_forcedRecovery_carriesFullFreeze`](../../test/unit/SecurityToken.t.sol#L697) | A full freeze is re-applied at the destination and cleared on the lost wallet, and the whole balance moves |
| [`test_forcedRecovery_partialFreezeLeavesExistingBalanceUnfrozen`](../../test/unit/SecurityToken.t.sol#L792) | A partial freeze is **additive**: with a balance already at the destination, only the incoming hold is frozen and the destination is not fully frozen |
| [`test_forcedRecovery_fullFreezeCoversPreExistingBalance`](../../test/unit/SecurityToken.t.sol#L810) | A full freeze **covers the whole destination**: it is frozen, and sending even one wei of the tokens already there reverts `SenderAddressFrozen` |

Recovery relocates a position; it does not launder a hold. The asymmetry in the last two is deliberate: a partial freeze is a property of a *lot*, so it moves with the tokens it applies to, while a full freeze is a property of the *investor*, so it applies to everything they hold at the destination. The identity check requires that the destination belongs to the same investor, which is what makes the second behaviour intended rather than collateral damage.

Clearing the lost wallet's freeze used to leave no event (review finding 9). The event sequence is asserted in [`test_forcedRecovery_emitsTheFullFreezeEventSequence`](../../test/scenario/Regressions.t.sol#L532).

### The gate is bypassed

| Test | Asserts |
| :--- | :------ |
| [`test_forcedRecovery_succeedsWhenComplianceRejects`](../../test/unit/SecurityToken.t.sol#L751) | With the module rejecting, recovery still moves the whole balance and supply is unchanged |
| [`test_forcedRecovery_succeedsIntoFrozenWallet`](../../test/unit/SecurityToken.t.sol#L766) | A fully frozen destination does not block it, and stays frozen afterwards |

Recovery skips the transfer gate entirely rather than relaxing it, for the same reason it skips the pause. Every check the gate performs is either already made by `forcedRecovery` itself (destination verified, same investor, sender's freeze cleared, exact balance) or is the wrong question to ask during an incident. The frozen-destination case is the sharper of the two: without the bypass, the operation would refuse to proceed because of a state it re-applies moments later.

---

## Fuzz

| Test | Asserts |
| :--- | :------ |
| [`testFuzz_transferConservesSupply`](../../test/unit/SecurityToken.t.sol#L871) | For any amount up to the balance, the two balances still sum to the minted amount and total supply is unchanged |
| [`testFuzz_recoveryConservesSupply`](../../test/unit/SecurityToken.t.sol#L884) | For any partial freeze up to the balance, with or without a full freeze, recovery empties the lost wallet, moves the whole balance, carries exactly that partial freeze and full-freeze flag, and leaves supply unchanged |
| [`testFuzz_cannotMoveFrozenPortion`](../../test/unit/SecurityToken.t.sol#L908) | For any freeze and send amount, a send within the unfrozen balance settles, and one above it reverts `InsufficientUnfrozenBalance(from, free, send)` |

Supply conservation under recovery is the property most worth fuzzing: recovery touches balances, freeze state and the registry in one call, and an error in the ordering would show up as tokens created or destroyed. The same properties across arbitrary *sequences* are [`invariant_balancesSumToTotalSupply`](../../test/invariant/Invariants.t.sol#L126) and [`invariant_supplyMatchesMintsMinusBurns`](../../test/invariant/Invariants.t.sol#L138).
