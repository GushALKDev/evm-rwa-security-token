# 🚀 Guide 6: Improvements

**Version:** 1.0
**Prerequisites:** [Guide 4: Trade-offs](./04-tradeoffs.md)

---

## 📋 Table of Contents

1. [Scope of this guide](#1-scope-of-this-guide)
2. [Restoring the ERC-3643 identity hierarchy](#2-restoring-the-erc-3643-identity-hierarchy)
3. [Partitions and a strict per-acquisition lockup](#3-partitions-and-a-strict-per-acquisition-lockup)
4. [Governance hardening](#4-governance-hardening)
5. [Upgradeability](#5-upgradeability)
6. [Dividend distribution (the planned stretch unit)](#6-dividend-distribution-the-planned-stretch-unit)
7. [Operational and tooling improvements](#7-operational-and-tooling-improvements)
8. [Priority table](#8-priority-table)

---

## 1. Scope of this guide

This guide catalogs what a **production** version would add back, and what a *next* iteration of the POC could reasonably build. Each item names the [trade-off](./04-tradeoffs.md) it reverses and what that reversal costs. Nothing here is required for the POC to be coherent; the POC is a deliberate subset, and this is the map from the subset back to the full instrument.

---

## 2. Restoring the ERC-3643 identity hierarchy

The flat registry collapses ONCHAINID, `IdentityRegistryStorage`, `TrustedIssuersRegistry`, and `ClaimTopicsRegistry` into one contract. A production deployment serving **multiple tokens or multiple issuers** would restore the split:

- **Per-investor ONCHAINID** so one KYC'd identity is reused across every token the investor holds.
- **`TrustedIssuersRegistry`** so more than one KYC provider can attest, each scoped to the claim topics they are trusted for.
- **`ClaimTopicsRegistry`** so the required claim set is configurable per token.

**Cost:** four contracts and a resolution step on every identity read, versus one `SLOAD` today. Justified only once the single-token / single-issuer assumption breaks. The trust model is already preserved (see [Guide 4 §2.1](./04-tradeoffs.md#21-onchainid-collapsed-into-a-flat-registry)), so this is a scaling change, not a security fix.

---

## 3. Partitions and a strict per-acquisition lockup

The single most consequential exclusion. Adding **ERC-1400 partitions** (tranches) would give each parcel of tokens its own identity, which unlocks:

- A **strict per-acquisition lockup**: receiving dust locks only the dust, because each parcel carries its own clock. This removes the reason the current design must use "from initial acquisition" (see [Guide 2 §6](./02-mathematics.md#6-the-lockup-clock)).
- **Heterogeneous rights**: different vesting, different classes, different voting, on partitions of the same token.

**Cost:** partitions turn a fungible balance into a set of labeled sub-balances, which touches every transfer, every rule, and every balance read. It is the largest architectural change in this list and only worth it for an instrument that actually has multiple tranches or classes.

---

## 4. Governance hardening

The accepted centralization (ISSUER = admin, self-grants roles) stays in a production build, but its **exercise** is hardened:

```
   Today                          Production
   ─────                          ──────────
   single admin key       ──►     DEFAULT_ADMIN_ROLE behind a multisig
   instant role grant     ──►     timelock on role grants + engine swaps
   instant module change  ──►     visible, delayed governance action
```

The trust assumption is unchanged: the issuer remains the authority. What changes is that acting on that authority becomes **observable and contestable before it takes effect**. This is the mitigation path already named in the [README threat model](../README.md#2-issuer-level-authority-accepted-not-defended) and [Guide 4 §4.1](./04-tradeoffs.md#41-issuer-level-authority-is-centralized). `CUSTODIAN_ROLE` in particular should sit behind hardware custody and an approval process tied to the legal determination that a wallet is genuinely lost.

---

## 5. Upgradeability

The POC has no proxies by design. A production instrument outlives any single implementation, so it would add:

- A **UUPS or transparent proxy** on the token and the engine, so bugs can be patched without migrating balances.
- A **factory** if more than one series is ever issued.

**Cost:** an indirection layer to read through and a new class of upgrade-safety concerns (storage layout, initializer discipline). Orthogonal to the identity/compliance architecture, which is why it is out of scope here (see [Guide 4 §2.5](./04-tradeoffs.md#25-no-upgradeability-proxies-or-factory)).

---

## 6. Dividend distribution (the planned stretch unit)

The one improvement already on the [ROADMAP](./ROADMAP.md) (Phase 8, stretch). A real-estate note pays income, and holders should receive it pro-rata **without iterating the holder set** (which is unbounded).

The design is the **accumulator pattern**:

```
   dividendsPerShare  += deposited / totalSupply        (on each income deposit)
   owed(holder)        = balanceOf(holder) × dividendsPerShare − correction(holder)
   correction(holder)  adjusted in the token's transfer hook so a transfer
                       cannot double-claim across sender and recipient
```

- **Pull, not push:** holders claim; the contract never pushes to a list of addresses.
- **Reentrancy-guarded** claim path.
- **Not `ERC20Votes` / `Snapshot`:** no per-block checkpoint history, because dividends need a running accumulator, not a historical balance lookup.

The correction term is what keeps it O(1): a transfer updates both parties' corrections so each is owed exactly their share and no more. Only built if the core is complete and tested, and only after explicit confirmation.

---

## 7. Operational and tooling improvements

Smaller items that would round out a production deployment:

| Improvement | What it adds |
|:---|:---|
| **Per-investor lockup snapshot** | Snapshot the lockup period at acquisition, so a later `setLockupPeriod` does not retroactively move existing holders (see [Guide 4 §3.3](./04-tradeoffs.md#33-lockup-period-applies-to-existing-clocks)) |
| **Batch onboarding** | `registerIdentity` over an array, to amortize gas across a placement |
| **Recovery approval trail** | An on-chain record linking a `forcedRecovery` to the off-chain legal determination |
| **Compliance module for accreditation** | A module gating on the `accredited` flag already stored in the identity record |
| **Event-indexed subgraph** | The holder set, freeze state, and recovery history are fully reconstructable from events; a subgraph would surface them |
| **Formal verification** | The supply-conservation and frozen-≤-balance invariants (see [Guide 5 §7](./05-implementation.md#7-invariants)) are good candidates for a prover, not just fuzzing |

---

## 8. Priority table

| Improvement | Trigger that justifies it | Effort | Reverses |
|:---|:---|:---|:---|
| Governance hardening (multisig + timelock) | Any real deployment | Low | §4.1 accepted risk |
| Dividend distributor | The note pays income | Medium | (new capability) |
| Per-investor lockup snapshot | Period is ever changed post-issuance | Low | §3.3 simplification |
| ERC-3643 identity hierarchy | Second token or second issuer | High | §2.1 scope cut |
| Upgradeability + factory | Instrument must outlive its code | Medium | §2.5 scope cut |
| ERC-1400 partitions | Multiple tranches / strict per-parcel lockup | High | §2.4 scope cut |

The ordering is roughly "reward per unit of effort for *this* instrument". Governance hardening is cheap and always worth it; partitions are expensive and only worth it if the instrument genuinely has tranches.

---

**See also:**
- [Guide 4: Trade-offs](./04-tradeoffs.md) - the decisions these improvements reverse
- [ROADMAP](./ROADMAP.md) - what is actually planned
- [README: standards and scoping](../README.md#standards-and-scoping) - the full scope argument
