# Guide 7: Security

**Version:** 1.0
**Prerequisites:** [Guide 3: Architecture](./03-architecture.md)
**Next:** [Guide 8: Review Notes](./08-review-notes.md)

---

## Table of Contents

1. [Role and permission matrix](#role-and-permission-matrix)
2. [Threat model](#threat-model)
3. [Trust assumptions and limitations](#trust-assumptions-and-limitations)
4. [Static analysis](#static-analysis)

---

## Role and permission matrix

Three roles, using OpenZeppelin `AccessControl`. ISSUER is the `DEFAULT_ADMIN_ROLE` (`0x00`) and administers the other two.

| Capability | Contract | ISSUER | AGENT | CUSTODIAN |
|---|---|:---:|:---:|:---:|
| `mint`, `burn` | SecurityToken | X | | |
| `setAddressFrozen`, `freezePartialTokens`, `unfreezePartialTokens` | SecurityToken | | X | |
| `pause`, `unpause` | SecurityToken | | X | |
| `forcedRecovery` | SecurityToken | | | X |
| `registerIdentity`, `removeIdentity` | IdentityRegistry | | X | |
| `setClaimSigner` | IdentityRegistry | X | | |
| `setMaxHolders` | MaxHoldersModule | | X | |
| `setLockupPeriod` | LockupModule | | X | |
| `setCountryRestricted` | CountryRestrictionModule | | X | |
| `grantRole`, `revokeRole` | every contract | X | | |
| `addModule`, `removeModule`, `bindToken` | ModularCompliance | X | | |
| `setDocument`, `removeDocument` | DocumentRegistry | X | | |
| `deposit` | DividendDistributor | X‡ | ‡ | |
| `registerIdentityWithAttestation` | IdentityRegistry | \* | \* | \* |
| `claim` | DividendDistributor | † | † | † |

\* Permissionless: anyone may submit, authorization comes from the claim signer's signature.
† Holder-facing: any account may claim, and only ever its own accrued entitlement.
‡ Gated by `AGENT_ROLE` on the distributor, which its constructor grants to the issuer only. The operational agent holds it only if the issuer grants it.

The split is meant to reflect how a regulated desk actually operates. **AGENT** is the compliance officer: an operational role, used daily, to onboard investors and freeze balances. **CUSTODIAN** is the recovery role, used rarely and under a legal process. They are separate so that day-to-day compliance operations carry no power to seize an investor's position. **ISSUER** controls supply and configuration but cannot freeze or recover directly.

Three edges worth flagging:

- **The `SecurityToken` contract itself holds `AGENT_ROLE` on the `IdentityRegistry`.** `forcedRecovery` must retire the lost wallet from the registry, and `removeIdentity` is agent-gated. The role is held by the contract, not by a person. It unlocks every agent function on the registry (`removeIdentity` and both `registerIdentity` overloads), but the token's code calls only `removeIdentity`, and only inside recovery.
- **ISSUER can grant itself AGENT and CUSTODIAN.** The separation above is an operational control, not a cryptographic one. See [Threat model](#threat-model) for why that is deliberate and what it does and does not protect.
- **`deposit` is `AGENT_ROLE` on the distributor, and its constructor grants that role to the issuer.** Income originates from the issuer's collections on the underlying note, so the two coincide by default; the role exists so a paying agent can be delegated the deposit duty without also holding admin. The gate is not about trust in the amount: it is that an open `deposit` would let anyone perturb the accumulator every holder's entitlement is computed from.

## Threat model

Written against the finished implementation. Four attack surfaces: getting a transfer past the gate, reentering through the external calls the gate makes, abusing recovery, and compromising a key. The first three are properties of the code; the fourth is partly a trust assumption the design accepts rather than defends.

### 1. Compliance bypass (defended)

The question is whether any balance can move without clearing the gate. The structural answer is that OZ v5 routes `transfer`, `transferFrom`, `_mint` and `_burn` through a single `_update`, so overriding it leaves no ERC-20 entrypoint uncovered, including any later entrypoint that routes through `_update`.

| Bypass attempt | Why it fails |
|---|---|
| Call a module or the engine directly to fake a settled transfer | Lifecycle hooks are `onlyToken` on the engine and `onlyCompliance` on each module. Only the bound token can claim a move happened |
| Register a module that never updates, then walk through its stale rule | `addModule` reverts (`ModuleNotBound`) unless the module already names this engine, so a module whose `onlyCompliance` gate would reject every call cannot be registered |
| Re-point a module at a second engine to corrupt accumulated state | The binding is `immutable`; there is no rebind path |
| Bind a second token to drive the hooks | `bindToken` reverts once a token is set |
| Move the frozen portion of a balance | The gate checks `amount <= balanceOf(from) - frozenTokens[from]`, and `freezePartialTokens` refuses to push the frozen amount above the balance, so the subtraction cannot underflow |
| Keep selling after compliance withdraws the identity | Both ends are identity-checked, not just the recipient, so `removeIdentity` suspends the position in both directions rather than only capping incoming transfers |
| Sit out the lockup by receiving dust to reset someone else's clock | The clock starts only on the 0→positive transition and is never overwritten while non-zero (`lockStart != 0`), so a 1-wei send cannot re-lock a victim |
| Inflate the holder count to exhaust the cap and DoS onboarding | Self-transfers are discarded in the hook. **This was a real bug**, found by the invariant suite: a full-balance self-transfer made `balanceOf(to) == amount` read as "joined from zero" while the sender was plainly not empty, so the signals failed to cancel and anyone could pump the count for free |
| Deflate the holder count to walk past the cap | Every stateful hook ignores a zero amount. **This was a real bug**, found in review: a zero-amount send from a verified wallet holding nothing read as "the sender left", and `transferFrom(emptyWallet, x, 0)` needs no allowance, so any address could drain the count, admit holders past the cap, and then make legitimate exits underflow (see [Review notes](./08-review-notes.md)) |
| Attach a holder cap or a lockup to a token that already has holders | `addModule` reverts (`ModuleCannotBind`): those modules refuse a token with supply, and every stateful module refuses a second attach |

The last rows are the honest part of this section. The holder-count and lockup modules both infer transitions from post-transfer balances rather than reading pre-transfer state, and that inference is where the bugs live. `invariant_holderCountMatchesReality` cross-checks the incremental count against enumerated real balances on every run, and its handler now issues zero amounts, full-balance moves and `transferFrom`; reintroducing the zero-amount bug makes it fail.

What is *not* defended: a rule the module set does not encode is not enforced, the gate does not check the `transferFrom` spender, and zero-amount transfers pass every module. Those are listed with the other accepted limitations in [Trust assumptions and limitations](#trust-assumptions-and-limitations).

### 2. Reentrancy (defended, mostly structurally)

The token makes external calls to the registry and to the engine, and the engine calls out to every module, so the surface exists on the transfer path even though no ether and no arbitrary callee is involved there.

The ordering in `_update` is CEI: checks, then `super._update` settles balances, then the engine hook fires. A module reentering the token during that hook therefore observes **already-settled** balances and gets no inconsistent intermediate state to exploit; it would simply face the gate again as a fresh transfer.

`forcedRecovery` carries `nonReentrant` on top of that, for a specific reason: it is the one function that mutates freeze state *around* a transfer (snapshot, clear, move, re-apply). A reentrant call landing between the clear and the re-apply is the one window where the freeze could be dropped, and the guard closes it. `_recovering` is set and cleared within that same guarded call, so the gate exemption cannot leak into any other transaction.

The residual assumption: **modules are trusted code the issuer registers**, not arbitrary third-party contracts. A malicious module can revert every transfer (a denial of service the issuer can undo by removing it) and can consume unbounded gas in the hook fan-out, which iterates all modules without a cap. Vetting what gets registered is a governance responsibility, not a property the engine enforces.

`DividendDistributor` is the first contract here that moves value *out* to an arbitrary address, which makes it the first place where reentrancy is a live concern rather than a structural one. `claim` records the withdrawal before transferring (CEI) and carries `nonReentrant` on top, because the settlement currency is external code: a token with a transfer callback, or an outright malicious one, gets control after the payout is recorded. Both `deposit` and `claim` are guarded. The [test suite](./tests/13-dividend-distributor.md#claiming) drives an attack with a currency that reenters `claim` from inside its own `transfer` and one that reenters `deposit` from inside `transferFrom`; each records that it attempted the reentry and the test asserts the guard's error. For `claim` the guard is the first line rather than the only one: the withdrawal is recorded before the payout, so a reentrant claim would also find nothing left. `test_forcedRecovery_isReentrancyGuarded` does the same for recovery, with a registered module holding `CUSTODIAN_ROLE` that reenters from the recovery's own hook. The distributor also never pushes: it pays only the caller's own entitlement, so one holder who cannot receive the currency cannot block anyone else.

### 3. Recovery abuse (constrained and auditable, not prevented)

`forcedRecovery` moves an investor's entire balance on a custodian's say-so, exempt from the pause and from every compliance rule. That is the largest single power in the system, so what constrains it matters.

- **Destination must be verified** and **must carry the same `investorId` as the lost wallet**. Without the second check, a custodian could recover into any verified address, including one they control as an onboarded investor, and, via the freeze carry-over, freeze whatever that address already held.
- **The freeze state travels with the position.** A partial freeze is additive at the destination; a full freeze applies to the whole destination wallet, which is intentional, since the `investorId` check already requires it to belong to the same investor. Recovery relocates a hold, it does not launder one.
- **The lost wallet is evicted** from the registry in the same call, so it can no longer send or receive. The eviction is not permanent: an agent can register the wallet again, after which it can hold the token. Removal clears the verification but keeps the `investorId`, so a wallet the agent had already suspended can still be recovered.
- **The lockup travels with the position.** Recovery does not restart the holding period: the destination takes the lost wallet's lockup start, or keeps its own if that is earlier.
- **Supply is unchanged** and every recovery emits `RecoverySuccess` naming both wallets and the carried freeze state.
- **Unclaimed income travels with the position.** This did not come for free. Settled as an ordinary transfer, the accumulator leaves accrued dividends on the lost wallet, so the tokens are rescued while the money stays claimable by whoever holds the compromised keys. The distributor branches on `recovering()` and carries the entitlement across; the behaviour is [tested end to end](./tests/13-dividend-distributor.md#forced-recovery) against the real recovery path, not only against a mock.

The limit, stated plainly: this is deterrence and auditability, not prevention. A compromised custodian key can still shuffle a victim's position between the victim's own wallets. And the `investorId` constraint only holds as far as the registry is honest: **a custodian key plus an agent key together** can link an attacker wallet to the victim's `investorId` and recover into it. What no lone key can do is act invisibly: the destination is a KYC-identified investor, and the event trail is on-chain.

### 4. Key compromise and issuer authority

Access control here spans two threat models that are easy to conflate and should not be. One is a risk the design defends against. The other is a trust assumption the design accepts.

#### 4.1 Operational key compromise (defended)

The keys used most often are the ones most likely to leak. `AGENT_ROLE` is exercised daily to onboard investors and manage freezes; `CUSTODIAN_ROLE` is exercised rarely but holds the power to move balances. Separating them is real defense-in-depth over the exposed surface:

- A **compromised AGENT key** can freeze balances, onboard bogus investors, remove identities (suspending positions), set any wallet's `investorId`, change the holder cap, the lockup period and the blocked countries, and pause the token. It **cannot** perform `forcedRecovery`, so it cannot move an existing investor's position, and it cannot mint or burn.
- A **compromised CUSTODIAN key** can perform recovery. It cannot mint, burn or freeze, and its only write to the identity registry is the eviction of the lost wallet that recovery performs.

Neither key alone reaches the other's powers, which is the point of the split. But the containment is asymmetric, and the honest version is worth stating: **a compromised CUSTODIAN key is the more dangerous of the two.**

Section 3 above sets out exactly how far the `investorId` constraint contains that key and where it stops. The operational conclusion is what belongs here: since recovery is **deterred and auditable rather than prevented**, and since the rule set offers no secondary containment (recovery is exempt from it by design), `CUSTODIAN_ROLE` is the role a production deployment should hold to the highest key-management standard (multisig, hardware custody, an approval process tied to the legal determination that a wallet is genuinely lost) rather than the one it treats as rarely-used and therefore low-risk. Frequency of use is not the same as blast radius.

#### 4.2 Issuer-level authority (accepted, not defended)

**ISSUER holds `DEFAULT_ADMIN_ROLE` and can grant itself `AGENT_ROLE` and `CUSTODIAN_ROLE` at will.** This is an accepted centralization assumption, not an oversight.

It is faithful to ERC-3643 and to the regulatory reality the standard encodes: the issuer is the responsible party for the instrument. They answer to the regulator, they are liable to holders, and they are the entity a court orders to act. A token that could refuse the issuer would be a token whose issuer cannot discharge their legal obligations. **The issuer is the authority, not an adversary the token defends against.**

The consequence, stated plainly: the AGENT/CUSTODIAN separation is an **operational** control, not a cryptographic one. It constrains compromised operational keys. It does not constrain a malicious or compromised issuer admin key, which can assume any role and do anything either role can do.

**Mitigation path, not built here.** A production deployment would keep this authority model and harden its exercise: `DEFAULT_ADMIN_ROLE` behind a multisig, ideally with a timelock, so that self-granting a role or swapping the compliance engine becomes a visible, delayed governance action rather than a single-key transaction. The trust assumption stays; what changes is that acting on it is observable and contestable before it takes effect. That is governance infrastructure, orthogonal to the architecture this POC demonstrates, and deliberately out of scope.

## Trust assumptions and limitations

What the design accepts rather than defends, in one place. Each item is either tested as it behaves or follows from the code named.

| Assumption or limitation | What it means |
|---|---|
| **Issuer authority** | `DEFAULT_ADMIN_ROLE` can grant itself `AGENT_ROLE` and `CUSTODIAN_ROLE`, remove modules and anchor documents. The AGENT/CUSTODIAN split contains compromised operational keys, not the issuer (see [4.2](#42-issuer-level-authority-accepted-not-defended)). |
| **Modules are trusted code** | A registered module can revert every transfer or burn gas in the hook fan-out. The engine bounds the fan-out at 25 modules; vetting what gets registered is governance. A rule no module encodes is not enforced. |
| **The holder cap counts wallets** | `MaxHoldersModule` counts addresses with a balance, not investors. One investor with two wallets counts twice; a regulation that counts holders of record or beneficial owners would need the count keyed by `investorId`. |
| **The `transferFrom` spender is not checked** | The gate checks sender and recipient only. An unverified or frozen spender can move tokens between two verified, unfrozen holders within an allowance (`test_transferFrom_spenderIsNotChecked`). ERC-3643 behaves the same way. |
| **Allowances survive recovery** | Allowances a lost wallet granted stay in place and are not carried to the new wallet. They cannot move anything while the lost wallet holds nothing and stays unregistered. |
| **Removed wallets can be registered again** | `removeIdentity` suspends a wallet; the agent (or a new attestation) can register it again. Recovery removes the lost wallet the same way. |
| **Signer rotation back to an old signer** | Rotating the claim signer invalidates outstanding attestations; rotating back to the old signer makes the unsubmitted ones valid again, unless a write to the record has advanced the nonce since. |
| **No fee-on-transfer or rebasing currency** | `deposit` credits the requested amount without measuring what arrived. Such a currency would leave the distributor owing more than it holds; nothing detects it. |
| **Zero-amount Transfer events** | Modules judge value movements only, so anyone can call `transferFrom(verifiedA, verifiedB, 0)` without an allowance and emit a `Transfer` event between two verified holders. This is standard ERC-20 behaviour, limited here to verified, unfrozen addresses while the token is not paused. |
| **`setLockupPeriod` is retroactive** | The period applies to every running clock: lengthening it re-locks holders whose original period had ended, shortening it releases holders early (`test_setLockupPeriod_appliesRetroactively`). |
| **Stateful modules cannot join a live token** | `MaxHoldersModule` and `LockupModule` refuse a token with supply, and no stateful module can be attached twice. `DividendDistributor` can join a live token once. Adding a holder cap or a lockup to an issued token means a new deployment. |
| **Removing a stateful module is permanent** | A removed `MaxHoldersModule`, `LockupModule` or `DividendDistributor` cannot be attached again, and while supply exists no new holder cap or lockup can be attached either, so removing one of those two rules cannot be undone (`test_addModule_rejectsReattachingARemovedStatefulModule`, `test_removingLockup_releasesLockedHolders_andCannotReturn`). A new `DividendDistributor` can still join: it starts from zero and pays only income deposited after it joins, while the removed one keeps paying what it had accrued (`test_distributor_lateAttachSplitsLaterDeposits`, `test_distributor_afterRemoval_refusesDepositsAndPaysAccrued`). |
| **A pause stops token movements only** | Mint, burn, transfer and transferFrom stop; forced recovery, administration, `deposit` and `claim` do not (`test_pause_againstEachRoleAction`). |
| **Deploy defaults every role to the broadcaster** | With `RWA_ISSUER`, `RWA_AGENT` and `RWA_CUSTODIAN` unset, one key holds all three roles, which suits a local run only. `RWA_ISSUER` must be the broadcaster, since the wiring is admin-gated; a real deployment needs a deploy-then-handover step. |
| **No upgradeability** | No proxies and no factory. A change to a contract means a redeployment. |
| **No EIP-1271** | The attestation path compares an ECDSA-recovered address with the claim signer; a contract cannot be the claim signer (`test_contractSigner_isNotSupported`). |

## Static analysis

Run on `src/` with Slither 0.11.6 (`slither . --filter-paths 'lib/|test/|script/'`) and Aderyn 0.6.8 (`aderyn . --src src`).

| Tool and category | Count | Triage |
|---|---|---|
| Slither `incorrect-equality` | 9 | By design: the modules infer transitions from balance equalities and use zero as the "no clock" sentinel. Three of these lines in `MaxHoldersModule` were where finding 1 lived; the zero-amount guards fixed it |
| Slither `timestamp` | 7 | By design: KYC expiry and lockup comparisons on a scale of days |
| Slither `shadowing-local` | 6 | False positive: parameter names in interface declarations |
| Slither `calls-loop` | 5 | By design: loops over the registered modules, capped at 25 |
| Slither `unused-return` | 2 | By design: `EnumerableSet.add` after a `contains` check, and an upsert in `DocumentRegistry` |
| Slither `unimplemented-functions` | 2 | False positive: `MaxHoldersModule` and `LockupModule` do override `isPlugAndPlay` |
| Slither `reentrancy-benign` | 1 | `forcedRecovery` writes after calling the trusted registry, under `nonReentrant` |
| Aderyn state change after external call | 13 | Reads of the trusted token or registry before a write, in guarded functions or in hooks only the engine can call |
| Aderyn centralization risk | 29 | The issuer and agent roles, an accepted assumption (see above) |
| Aderyn unchecked return, uninitialized local, unused import, unspecific pragma, PUSH0 | 15, 5, 4, 15, 16 | `_grantRole` and set results not needed; loop counters; imports needed for `@inheritdoc`; solc pinned in `foundry.toml`; the target EVM supports PUSH0 |
| Aderyn empty block, `nonReentrant` not first, loop with revert, state change without event | 3, 2, 1, 3 | Stateless hooks; `onlyRole` makes no external call; `bindToken` refuses a mismatched module; distributor bookkeeping that follows from `Transfer` events |

The true positives both tools raised during the review (the token's registry and engine references could be `immutable`) were fixed in round 2.

---

**See also:**
- [Guide 3: Architecture](./03-architecture.md) - the gate, the recovery sequence and the binding graph these defenses rest on
- [Guide 4: Trade-offs](./04-tradeoffs.md) - the accepted risks as a decision register
- [Guide 8: Review Notes](./08-review-notes.md) - the bugs the review found and how each was fixed
