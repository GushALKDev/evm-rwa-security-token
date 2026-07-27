# ⚖️ Guide 4: Trade-offs

**Version:** 1.0
**Prerequisites:** [Guide 3: Architecture](./03-architecture.md)
**Next:** [Guide 5: Implementation](./05-implementation.md)

---

## 📋 Table of Contents

1. [How to read this guide](#1-how-to-read-this-guide)
2. [Scope decisions](#2-scope-decisions)
3. [Design decisions inside the built code](#3-design-decisions-inside-the-built-code)
4. [Accepted risks](#4-accepted-risks)
5. [Trade-off summary table](#5-trade-off-summary-table)

---

## 1. How to read this guide

Every decision here is a *deliberate* exclusion or a *deliberate* choice between defensible alternatives, and each one buys or costs a security property. The most consequential arguments (the ONCHAINID collapse, the lockup model, the access-control threat model) are made in full in the [README](../README.md); this guide is the compact register of *what was decided and what the alternative would have cost*, with a pointer to the full argument where one exists.

A recurring theme: **excluding a feature sometimes forces a different rule, and the two cannot be reasoned about separately.** The clearest case is partitions → lockup model, below.

---

## 2. Scope decisions

What was left out of the ERC-3643 / ERC-1400 surface, and why the omission is safe.

### 2.1 ONCHAINID collapsed into a flat registry

The four-contract ERC-3643 identity hierarchy exists to let **one identity be reused across many tokens and issuers**. With a single token and a single issuer, it is ceremony without benefit. The part that carries the actual security value, that verification should not rest on trusting whoever writes to the registry, is preserved through the signed attestation path.

- **Cost of collapsing:** an identity here cannot be shared across tokens.
- **Preserved:** the cryptographic trust model (signature over caller). See [README](../README.md#what-was-deliberately-left-out-and-why).

### 2.2 `TrustedIssuersRegistry` reduced to a single claim signer

The registry answers "which issuers may attest which claim topics". With one KYC provider and one claim topic, that collapses to one address. The cryptographic verification, which is the substance, is kept as EIP-712 recovery against that one signer.

### 2.3 No claim topics or claim schemes

Attributes (`country`, `accredited`, `kycExpiry`) are **typed struct fields**, not generic claim blobs. Generic claims buy extensibility this POC has no use for, at the cost of making every rule parse bytes. Typed fields keep the record in one storage slot (see [Guide 2 §4](./02-mathematics.md#4-storage-packing-of-the-identity-record)) and the rules readable.

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

The nonce is post-incremented *before* the digest is built, so a replay recovers a different address and fails the signer check. The alternative (check signature, then bump nonce) leaves a reentrancy-shaped window and is less CEI-clean. See [Guide 2 §3](./02-mathematics.md#3-replay-the-three-axes-and-what-closes-each).

### 3.3 Lockup period applies to existing clocks

`setLockupPeriod` changes the period for everyone, evaluated against the *current* period rather than the one in force at acquisition. Shortening releases investors early; lengthening extends them.

- **Chosen:** the simple reading, one storage variable.
- **Alternative:** snapshot the period per investor at acquisition, which a production instrument would likely do. Noted as a known simplification in the contract's NatSpec.

### 3.4 `bindToken` / engine binding settable once

Both the token→engine and module→engine bindings are one-time. Rebinding a live engine would let a second token drive the lifecycle hooks of modules whose state was accumulated from the first, corrupting every stateful rule. The cost is zero (a module is cheap to redeploy); the property bought is that stateful rules cannot be hijacked.

### 3.5 One status-code function for `_update` and `canTransfer`

The transfer gate is implemented once and consumed two ways (revert vs bool), so the enforced rule and the advertised pre-check cannot drift. The alternative (two parallel implementations) is a classic source of "the front end said it would pass but the transfer reverted" bugs. See [Guide 3 §4](./03-architecture.md#4-the-transfer-gate-a-superset-check).

---

## 4. Accepted risks

Risks the design **accepts** rather than defends against, stated as trade-offs so they are not mistaken for oversights.

### 4.1 Issuer-level authority is centralized

ISSUER holds `DEFAULT_ADMIN_ROLE` and can self-grant `AGENT` and `CUSTODIAN`. This is faithful to ERC-3643 and to the regulatory reality it encodes: the issuer is the legally responsible party, the entity a court orders to act. A token that could refuse the issuer would be one whose issuer cannot discharge their legal obligations.

- **Accepted:** the issuer is the authority, not an adversary.
- **Mitigation path (not built):** put `DEFAULT_ADMIN_ROLE` behind a multisig + timelock, so self-granting a role becomes a visible, delayed governance action. Governance infrastructure, orthogonal to the architecture.

Full treatment: [README threat model §4.2](../README.md#42-issuer-level-authority-accepted-not-defended).

### 4.2 A compromised custodian key is deterred, not prevented

`forcedRecovery` can only target a destination that is already verified **and registered under the same `investorId` as the lost wallet**, so a custodian cannot move a balance to an unrelated third party. What a compromised key can still do is move a victim's position between that victim's own wallets, and, if the attacker can get a wallet of their own linked to the victim's `investorId` by the agent, out of the victim's control entirely. What it **cannot** do is hide: every recovery emits `RecoverySuccess` naming both wallets, the destination is a KYC-identified investor, and total supply is unchanged.

Recovery also bypasses the pause and the transfer gate, so no compliance rule limits it: a lockup still running or a frozen destination will not stop a custodian. That is deliberate, since the alternative is a compromised position stranded on a wallet the investor no longer controls, but it does mean the modular rule set is not a second line of defence against this key.

- **The mitigation is auditability, not prevention.** This is why `CUSTODIAN_ROLE` deserves the highest key-management standard, not the lowest because it is rarely used. Blast radius, not frequency, sets the standard. Full treatment: [README threat model §4.1](../README.md#41-operational-key-compromise-defended).

### 4.3 On-chain verification is a projection

`isVerified` means "someone attested KYC and it has not expired", not "this investor is KYC-clean". The chain cannot validate the underlying fact; `kycExpiry` is what keeps the projection honest over time. Accepted as inherent to any on-chain identity system.

---

## 5. Trade-off summary table

| Decision | Advantage | Cost / trade-off |
|:---|:---|:---|
| Flat registry (no ONCHAINID) | Simpler, one `SLOAD` per identity | Identity not reusable across tokens |
| Single claim signer | One address, one recovery check | No multi-issuer / multi-topic attestations |
| Typed attributes (no claim blobs) | Record in one slot, readable rules | Adding an attribute is a code change |
| No partitions | No tranche accounting complexity | Forces "from initial acquisition" lockup |
| No proxies / factory | Nothing to read through | Not upgradeable; a real deploy needs this |
| Incremental holder count | O(1) gas | Swap-at-cap subtlety; count can't drift |
| Lockup from initial acquisition | Immune to dust-relock griefing | Not strictly per-acquisition |
| One gate for revert + view | Enforcement and pre-check can't diverge | Slightly more indirection |
| ISSUER = admin, self-grants roles | Faithful to ERC-3643, issuer can act | Centralization (mitigate with multisig) |
| Recovery = verified destination only | Theft is attributable and legible | Not prevented, only deterred |

---

**See also:**
- [Guide 5: Implementation](./05-implementation.md) - how these decisions look in code
- [Guide 6: Improvements](./06-improvements.md) - what a production version would add back
- [README: standards and scoping](../README.md#standards-and-scoping) - the full scoping argument
