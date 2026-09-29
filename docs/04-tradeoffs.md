# Guide 4: Trade-offs

**Version:** 1.0
**Prerequisites:** [Guide 3: Architecture](./03-architecture.md)
**Next:** [Guide 5: Implementation](./05-implementation.md)

---

## Table of Contents

1. [How to read this guide](#1-how-to-read-this-guide)
2. [Scope decisions](#2-scope-decisions)
3. [Design decisions inside the built code](#3-design-decisions-inside-the-built-code)
4. [Accepted risks](#4-accepted-risks)
5. [Trade-off summary table](#5-trade-off-summary-table)
6. [Edge cases and griefing vectors](#6-edge-cases-and-griefing-vectors)

---

## 1. How to read this guide

Every decision here is a *deliberate* exclusion or a *deliberate* choice between defensible alternatives, and each one buys or costs a security property. The most consequential arguments are made in full elsewhere (the lockup model in the [README](../README.md#why-the-lockup-runs-from-initial-acquisition-not-from-each-acquisition) and [Guide 2](./02-mathematics.md#6-the-lockup-clock), the access-control threat model in [Guide 7](./07-security.md#threat-model)); this guide is the compact register of *what was decided and what the alternative would have cost*, with a pointer to the full argument where one exists.

A recurring theme: **excluding a feature sometimes forces a different rule, and the two cannot be reasoned about separately.** The clearest case is partitions → lockup model, below.

---

## 2. Scope decisions

What was left out of the ERC-3643 / ERC-1400 surface, and why the omission is safe.

### 2.1 ONCHAINID collapsed into a flat registry

The four-contract ERC-3643 identity hierarchy exists to let **one identity be reused across many tokens and issuers**. With a single token and a single issuer, it is ceremony without benefit. The part that carries the actual security value, that verification should not rest on trusting whoever writes to the registry, is preserved through the signed attestation path.

- **Cost of collapsing:** an identity here cannot be shared across tokens.
- **Preserved:** the cryptographic trust model (signature over caller). See the [README](../README.md#the-two-registration-paths).

### 2.2 `TrustedIssuersRegistry` reduced to a single claim signer

The registry answers "which issuers may attest which claim topics". With one KYC provider and one claim topic, that collapses to one address. The cryptographic verification, which is the substance, is kept as EIP-712 recovery against that one signer.

### 2.3 No claim topics or claim schemes

Attributes (`country`, `accredited`, `kycExpiry`) are **typed struct fields**, not generic claim blobs. Generic claims buy extensibility this POC has no use for, at the cost of making every rule parse bytes. Typed fields keep the verification attributes packed in one storage slot, with the investor id in a second (see [Guide 2 §4](./02-mathematics.md#4-storage-packing-of-the-identity-record)) and the rules readable.

### 2.4 ERC-1400 partitions omitted, which forces the lockup model

This is the trade-off worth dwelling on, because the exclusion **determines a security property downstream**.

```
   Partitions out of scope
            │
            ▼
   No per-parcel accounting
            │
            ▼
   Strict per-acquisition lockup cannot be implemented safely
            │                    (every receipt would re-lock the whole
            ▼                     fungible balance ⇒ dust-relock griefing)
   Lockup runs "from initial acquisition", clock never reset by later receipts
```

The strict "12 months from each acquisition" reading is only safe if each *parcel* carries its own clock, which is exactly what partitions provide. Without them, a literal implementation lets anyone re-lock a victim's whole position with a 1-wei transfer. So the rule is model 2 (from initial acquisition), and the anchored terms document is worded to match. Full argument and arithmetic: [Guide 2 §6](./02-mathematics.md#6-the-lockup-clock) and the [README](../README.md#why-the-lockup-runs-from-initial-acquisition-not-from-each-acquisition).

### 2.5 No upgradeability, proxies, or factory

A real deployment needs all three. They are **orthogonal** to the identity and compliance architecture being demonstrated, and a proxy layer would add indirection to read through with no insight gained. Explicitly a scope decision, not an oversight.

### 2.6 ERC-3643 surface: implemented and not implemented

Compared against the interfaces in the [EIP text](https://eips.ethereum.org/EIPS/eip-3643) and the T-REX reference (`IToken`, `IIdentityRegistry`, `IModularCompliance`, `IModule`). Sections 2.1 to 2.5 say why each part was left out; this table says which functions exist.

| Area | Implemented as in the standard | Implemented differently | Not implemented |
|---|---|---|---|
| Token | `pause`, `unpause`, `setAddressFrozen`, `freezePartialTokens`, `unfreezePartialTokens`, `isFrozen`, `paused`, `identityRegistry()`, `compliance()` (both return an address) | `transfer` / `transferFrom` also require the **sender** to be verified (the standard checks only the recipient). `mint` runs the modular rules and the freeze check (the standard lets `mint` bypass compliance). `mint` and `burn` are gated by `DEFAULT_ADMIN_ROLE`, not by an agent. `getFrozenTokens` is `frozenTokens`. `recoveryAddress(lost, new, onchainID)` is `forcedRecovery(lost, new)`: no ONCHAINID argument, the two wallets must share an `investorId`, it is gated by `CUSTODIAN_ROLE`, and it skips the pause and every compliance rule. A token-level `canTransfer` view is added | `forcedTransfer`, all seven `batch*` functions, `setIdentityRegistry`, `setCompliance` (both are fixed in the constructor), `onchainID`, `setOnchainID`, `version`, `setName`, `setSymbol` |
| Agent role | | OpenZeppelin `AccessControl` with `AGENT_ROLE`, `CUSTODIAN_ROLE` and `DEFAULT_ADMIN_ROLE` instead of `IAgentRole` (`addAgent`, `removeAgent`, `isAgent`) | |
| Identity registry | | `registerIdentity(user, country, accredited, kycExpiry[, investorId])` stores attributes instead of linking an `IIdentity` contract. `deleteIdentity` is `removeIdentity`. `isVerified` checks a stored flag and `kycExpiry`, not claims. `identity` returns the stored record. `investorCountry` is `country`. Re-registering overwrites a record, which stands in for `updateCountry` and `updateIdentity`. `registerIdentityWithAttestation` (EIP-712, one claim signer) is added | `batchRegisterIdentity`, `contains`, `identityStorage`, `issuersRegistry`, `topicsRegistry` and their setters |
| Registry split | | `TrustedIssuersRegistry` is reduced to one `claimSigner` | `IdentityRegistryStorage`, `ClaimTopicsRegistry`, ONCHAINID |
| Compliance | `addModule`, `removeModule`, `canTransfer`, `transferred`, `created`, `destroyed` | `bindToken` is one-shot and cannot be rebound. `getModules`, `getTokenBound` and `isModuleBound` are `modules`, `token` and `isModuleRegistered`. `addModule` also checks that the module names this engine, that `canComplianceBind` allows it, and that the module reads the bound token (`bindToken` checks the same for modules registered earlier). The engine accepts at most 25 modules, the T-REX limit | `unbindToken`, `isTokenBound`, `callModuleFunction` |
| Module | `name`, `isPlugAndPlay`, `canComplianceBind`, `isComplianceBound`, `bindCompliance`, `unbindCompliance` (called by the engine from `addModule` and `removeModule`) | `moduleTransferAction`, `moduleMintAction` and `moduleBurnAction` are `moduleTransferred`, `moduleCreated` and `moduleDestroyed`. `moduleCheck` takes no compliance argument. A module serves one engine, fixed in its constructor, rather than a list of bound compliances. A `token()` view is added | |

The last row follows T-REX for the reason T-REX has it. A stateful module such as T-REX's `MaxBalanceModule` reports `isPlugAndPlay() == false`, and its `canComplianceBind` refuses a compliance whose token already has supply. Here `MaxHoldersModule` and `LockupModule` refuse a token with supply, and every stateful module refuses to be attached a second time (see [Guide 3](./03-architecture.md#attaching-stateful-modules)). T-REX also gates `recoveryAddress` to an agent, where this repository uses a separate `CUSTODIAN_ROLE`.

The conformance suites in [`test/conformance/`](../test/conformance/) pin the remaining differences, compared by event signature (topic0) against the EIP text, the T-REX interfaces and the ERC-1643 issue:

- **Events that match:** `Paused`, `Unpaused`, `TokensFrozen`, `TokensUnfrozen`, `ModuleAdded`, `ModuleRemoved`, `ComplianceBound`, `ComplianceUnbound` and ERC-1643's `DocumentUpdated`.
- **Events that differ:** `AddressFrozen(address,bool)` against the standard's `(address,bool,address)`, which also names the agent; `RecoverySuccess(address,address,uint256,uint256,bool)` against `(address,address,address)`, which names the ONCHAINID; `IdentityRegistered(address,uint16,bool,uint64,bytes32,bool)` and `IdentityRemoved(address)` against the forms carrying an `IIdentity`; `IdentityRegistrySet` and `ComplianceSet` against `IdentityRegistryAdded` and `ComplianceAdded`; `TokenBound(address)` has the same signature but an indexed argument; ERC-1643's `DocumentRemoved(bytes32)` against `(bytes32,string,bytes32)`.
- **ERC-1643 behaviour:** the timestamp is a `uint64` (ABI-compatible with the issue's `uint256`), an empty hash or URI is refused although the issue calls the hash optional, and an unknown name reverts.
- **ERC-20 behaviour:** a transfer the gate refuses reverts rather than returning false, which ERC-20 allows; as in OpenZeppelin v5, spending an allowance emits no `Approval` event and an allowance of `type(uint256).max` is never decreased. EIP-712 signing matches the standard; contract signers (EIP-1271) are not supported.

---

## 3. Design decisions inside the built code

Choices made *within* the implemented contracts where a reasonable alternative existed.

### 3.1 Holder count: incremental vs enumeration

| Option | Cost |
|:---|:---|
| Enumerate balances to count holders | Unbounded gas; DoS as the holder set grows |
| **Incremental count in hooks** (chosen) | Must infer transitions from `balanceOf` after the move; must allow the swap-at-cap case |

The chosen path trades a little subtlety (the four-case transition table, the deadlock-avoiding swap allowance) for O(1) gas. See [Guide 2 §5](./02-mathematics.md#5-holder-count-transitions-without-enumeration).

### 3.2 Nonce consumed before signature verification

The nonce is post-incremented *before* the digest is built, so a replay recovers a different address and fails the signer check. The alternative (check the signature, then bump the nonce) is equally safe here, because no external call sits between the two; incrementing first keeps the effect ahead of the check as a matter of CEI style. The nonce advances on every write to the record (a signed registration, an agent registration and a removal), so no attestation issued before the latest write can be submitted after it. See [Guide 2 §3](./02-mathematics.md#3-replay-the-three-axes-and-what-closes-each).

### 3.3 Lockup period applies to existing clocks

`setLockupPeriod` changes the period for everyone, evaluated against the *current* period rather than the one in force at acquisition. Shortening releases investors early; lengthening extends them.

- **Chosen:** the simple reading, one storage variable.
- **Alternative:** snapshot the period per investor at acquisition, which a production instrument would likely do. Noted as a known simplification in the contract's NatSpec.

### 3.4 `bindToken` / engine binding settable once

Both the token→engine and module→engine bindings are one-time. Rebinding a live engine would let a second token drive the lifecycle hooks of modules whose state was accumulated from the first, corrupting every stateful rule. Redeploying a stateless module costs nothing. Redeploying a stateful one on a live token loses its accumulated state (holder count, lockup clocks, dividend corrections), which a new instance cannot rebuild from the hooks alone. The property bought is that stateful rules cannot be hijacked.

### 3.5 One status-code function for `_update` and `canTransfer`

The transfer gate is implemented once and consumed two ways (revert vs bool), so for transfers and mints the enforced rule and the advertised pre-check cannot drift (burn and forced recovery do not pass through the gate). The alternative (two parallel implementations) is a classic source of "the front end said it would pass but the transfer reverted" bugs. See [Guide 3 §4](./03-architecture.md#4-the-transfer-gate-a-superset-check).

### 3.6 Modules judge value movements only

Every module's `moduleCheck` returns true for a zero amount, and every stateful hook ignores one. A zero-amount transfer moves no value, adds or removes no holder and acquires or disposes of nothing, so no rule has anything to judge; the token-level identity, freeze and pause checks still apply to it. The cost is that anyone can emit a zero-value `Transfer` event between two verified, unfrozen holders through `transferFrom(a, b, 0)`, which needs no allowance: standard ERC-20 behaviour, limited here to verified addresses.

### 3.7 At most 25 modules

`ModularCompliance` accepts at most 25 modules, as T-REX does. Every transfer iterates them twice (the checks and the hooks), so the cap bounds that loop: a transfer measured at 100,089 gas with the three deployed rules costs 335,359 with 25 (`FOUNDRY_PROFILE=gas forge test --isolate --gas-report`).

---

## 4. Accepted risks

Risks the design **accepts** rather than defends against, stated as trade-offs so they are not mistaken for oversights.

### 4.1 Issuer-level authority is centralized

ISSUER holds `DEFAULT_ADMIN_ROLE` and can self-grant `AGENT` and `CUSTODIAN`. This is faithful to ERC-3643 and to the regulatory reality it encodes: the issuer is the legally responsible party, the entity a court orders to act. A token that could refuse the issuer would be one whose issuer cannot discharge their legal obligations.

- **Accepted:** the issuer is the authority, not an adversary.
- **Mitigation path (not built):** put `DEFAULT_ADMIN_ROLE` behind a multisig + timelock, so self-granting a role becomes a visible, delayed governance action. Governance infrastructure, orthogonal to the architecture.

Full treatment: [Guide 7, threat model §4.2](./07-security.md#42-issuer-level-authority-accepted-not-defended).

### 4.2 A compromised custodian key is deterred, not prevented

`forcedRecovery` can only target a destination that is already verified **and registered under the same `investorId` as the lost wallet**, so a custodian cannot move a balance to an unrelated third party. What a compromised key can still do is move a victim's position between that victim's own wallets, and, if the attacker can get a wallet of their own linked to the victim's `investorId` by the agent or through an attestation from the claim signer, out of the victim's control entirely. What it **cannot** do is hide: every recovery emits `RecoverySuccess` naming both wallets, the destination is a KYC-identified investor, and total supply is unchanged.

Recovery also bypasses the pause and the transfer gate, so no compliance rule limits it: a lockup still running or a frozen destination will not stop a custodian. That is deliberate, since the alternative is a compromised position stranded on a wallet the investor no longer controls, but it does mean the modular rule set is not a second line of defence against this key. The lifecycle hook still fires, and `LockupModule` carries the lockup start across rather than starting a new clock, so recovery neither extends nor shortens the holding period.

- **The mitigation is auditability, not prevention.** This is why `CUSTODIAN_ROLE` deserves the highest key-management standard, not the lowest because it is rarely used. Blast radius, not frequency, sets the standard. Full treatment: [Guide 7, threat model §4.1](./07-security.md#41-operational-key-compromise-defended).

### 4.3 On-chain verification is a projection

`isVerified` means "someone attested KYC and it has not expired", not "this investor is KYC-clean". The chain cannot validate the underlying fact; `kycExpiry` is what keeps the projection honest over time. Accepted as inherent to any on-chain identity system.

---

## 5. Trade-off summary table

| Decision | Advantage | Cost / trade-off |
|:---|:---|:---|
| Flat registry (no ONCHAINID) | Simpler, one registry call per identity check | Identity not reusable across tokens |
| Single claim signer | One address, one recovery check | No multi-issuer / multi-topic attestations |
| Typed attributes (no claim blobs) | Attributes packed in one slot, readable rules | Adding an attribute is a code change |
| No partitions | No tranche accounting complexity | Forces "from initial acquisition" lockup |
| No proxies / factory | Nothing to read through | Not upgradeable; a real deploy needs this |
| Incremental holder count | O(1) gas | Swap-at-cap subtlety; count can't drift |
| Lockup from initial acquisition | Immune to dust-relock griefing | Not strictly per-acquisition |
| One gate for revert + view | Transfer and mint pre-checks match enforcement | Slightly more indirection; burn and recovery are outside the view |
| ISSUER = admin, self-grants roles | Faithful to ERC-3643, issuer can act | Centralization (mitigate with multisig) |
| Recovery = verified same-investor destination only | Theft is attributable and legible | Not prevented, only deterred |


---

## 6. Edge cases and griefing vectors

Each row names the test that pins the behaviour. Tests in `EdgeCases`, `Regressions` and the conformance suites run against the deployed wiring.

| Surface | Trigger | Behaviour | Test |
|:---|:---|:---|:---|
| Holder cap | Agent lowers the cap below the live count | Reverts with `MaxHoldersBelowCurrentCount`; at exactly the count, a swap is admitted and a new holder only after an exit | `test_holderCap_loweredToCount_thenExitsAndEntries` |
| Holder cap | Anyone sends zero from an empty wallet, or calls `transferFrom(empty, x, 0)` | Count unchanged (bug 1, fixed) | `test_zeroAmountTransferFromByStranger_doesNotDeflateHolderCount` |
| Holder cap | One investor spreads a position over many wallets | Each wallet counts: a limitation, documented | none (by design) |
| Lockup | Griefer dusts a holder one second before expiry | Clock and unlock time unchanged | `test_griefing_oneWeiCannotRelockPosition` |
| Lockup | Agent changes the period while holders are locked | Applies to running clocks, both ways; documented | `test_setLockupPeriod_appliesRetroactively` |
| Lockup | Issuer removes the module while holders are locked | Everyone is released; the module cannot come back | `test_removingLockup_releasesLockedHolders_andCannotReturn` |
| Identity | KYC expires during the lockup, with unclaimed income | Position and income suspended; renewal restores the same schedule and pays the income | `test_kycExpiryDuringLockupAndWithUnclaimedIncome` |
| Identity | An unsubmitted attestation after a removal | Rejected: removal advances the nonce (bug 2, fixed) | `test_attestationSignedBeforeRemoval_isRejectedAfterIt` |
| Recovery | Destination is frozen, or the lost wallet partially frozen | Recovery proceeds; both freeze states arrive at the destination | `test_forcedRecovery_succeedsIntoFrozenWallet`, `test_forcedRecovery_carriesPartialFreeze` |
| Recovery | Destination is a same-investor wallet in a blocked jurisdiction | Recovery proceeds (rules are skipped by design) | `test_recovery_intoBlockedJurisdictionWalletOfSameInvestor` |
| Recovery | The recovered lost wallet claims income | `ClaimantNotVerified`; once registered again, `NothingToClaim` | `test_recoveredLostWallet_cannotClaim` |
| Recovery | A registered module reenters `forcedRecovery` from the hook | Rejected by the guard | `test_forcedRecovery_isReentrancyGuarded` |
| Dividends | One base unit of supply, one-unit deposits | Paid exactly | `test_dividends_smallestSupplyAndDeposit` |
| Dividends | Supply above 2^128 base units, one-unit deposits | The carried remainder pays out on the third deposit | `test_deposit_residueCarriesSubUnitRemainderIntoLaterDeposits` |
| Dividends | Currency sent to the distributor outside `deposit` | Not credited; entitlements unchanged | `test_dividends_directDonationIsNotCredited` |
| Dividends | Currency returns false or reverts on transfer | `claim` and `deposit` revert through SafeERC20 or the currency's error and leave no record | `test_dividends_currencyReturningFalse_failsTheClaimCleanly`, `test_dividends_currencyReturningFalse_failsTheDepositCleanly` |
| Dividends | Issuer removes the distributor with income unclaimed | Deposits refused, accrued income stays claimable | `test_distributor_afterRemoval_refusesDepositsAndPaysAccrued` |
| Dividends | Hostile currency reenters `claim` or `deposit` | Rejected by the guard | `test_claim_isReentrancyGuarded`, `test_deposit_isReentrancyGuarded` |
| Pause | Each role action while paused | Token movements stop; recovery, administration and the distributor do not | `test_pause_againstEachRoleAction` |
| Transfers | Anyone calls `transferFrom(a, b, 0)` between verified holders | Settles and emits `Transfer`; refused to unverified or frozen wallets | `test_zeroAmountTransferFrom_passesModulesButNotTheGate` |
| Transfers | Unverified or frozen spender with an allowance | Moves tokens between verified holders: a limitation, documented | `test_transferFrom_spenderIsNotChecked` |
| Documents | Empty URI, empty hash | Refused | `test_stricterInputs` |
| Documents | Longest name (32 bytes), 4 KiB URI, re-anchoring a name | Stored and read back; re-anchoring updates in place | `test_documents_longestNameAndLongUri`, `test_setDocument_updatesExisting` |
| Engine | 26th module | Refused with `ModuleLimitReached` | `test_addModule_capsTheModuleCount` |
| Engine | Hook fan-out at 25 modules | 335,359 gas for a transfer, against 100,089 with three modules (measured, not asserted) | `test_gas_transferAtModuleCap` (gas harness) |

---

**See also:**
- [Guide 5: Implementation](./05-implementation.md) - how these decisions look in code
- [Guide 6: Improvements](./06-improvements.md) - what a production version would add back
- [Guide 7: Security](./07-security.md) - roles, threat model and trust assumptions
