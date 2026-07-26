# 🏛️ Guide 3: Architecture

**Version:** 1.0
**Prerequisites:** [Guide 2: Mathematics & Cryptography](./02-mathematics.md)
**Next:** [Guide 4: Trade-offs](./04-tradeoffs.md)

---

## 📋 Table of Contents

1. [System overview](#1-system-overview)
2. [The identity registry](#2-the-identity-registry)
3. [The compliance engine and its modules](#3-the-compliance-engine-and-its-modules)
4. [The transfer gate: a superset check](#4-the-transfer-gate-a-superset-check)
5. [Lifecycle hooks and state consistency](#5-lifecycle-hooks-and-state-consistency)
6. [Document anchoring](#6-document-anchoring)
7. [Deployment order and the binding graph](#7-deployment-order-and-the-binding-graph)

---

> This guide describes how the parts wire together. The *rationale* for what was scoped out (ONCHAINID, partitions, proxies) and the access-control threat model are argued in full in the [README](../README.md) and are not repeated here.

---

## 1. System overview

Five contracts (plus shared `Roles` and an abstract module base), in two states: **built** (identity + compliance) and **designed** (`DocumentRegistry`, `SecurityToken`, wired by `ISecurityToken`/`IDocumentRegistry`).

```
                              ┌───────────────────────────────┐
        ISSUER (admin) ──────►│         SecurityToken         │
        AGENT (freeze/pause)  │   ERC20 + AccessControl +     │
        CUSTODIAN (recovery)  │   Pausable + ReentrancyGuard  │
                              └───┬───────────┬───────────┬───┘
                    reads identity│    checks │      fans │ lifecycle
                    on every xfer │     rules │     hooks │ (post-move)
                                  ▼           ▼           ▼
                      ┌────────────────┐  ┌───────────────────────────┐
                      │IdentityRegistry│  │     ModularCompliance     │
                      │  AccessControl │  │  AccessControl + Enumer-  │
                      │  + EIP712      │  │  ableSet<module>          │
                      └───────┬────────┘  └────┬──────────┬─────────┬─┘
                token holds    │               │          │         │
             AGENT_ROLE here ──┘         moduleCheck / moduleTransferred /
             (for recovery)              moduleCreated / moduleDestroyed
                                              ▼          ▼         ▼
                                     ┌────────────┐ ┌─────────┐ ┌────────┐
                                     │ MaxHolders │ │ Country │ │ Lockup │
                                     │   Module   │ │ Restr.  │ │ Module │
                                     └────────────┘ └─────────┘ └────────┘
                              ┌──────────────────┐
        ISSUER ──────────────►│ DocumentRegistry │  (hash + URI per name)
                              └──────────────────┘
```

Two invariants define the shape:

1. **The token references the engine, never the modules.** The rule set is pluggable at the engine, so it changes by governance action, not token redeploy.
2. **Every module answers to exactly one engine, and every engine to exactly one token.** Both bindings are set once and never rebindable. This is what keeps stateful rules from being corrupted by a second caller.

---

## 2. The identity registry

`IdentityRegistry` is the on-chain projection of an off-chain KYC process: the set of addresses allowed to hold the token, with the attributes rules are evaluated against. It collapses the ERC-3643 four-contract hierarchy (`IdentityRegistry`, `IdentityRegistryStorage`, `TrustedIssuersRegistry`, `ClaimTopicsRegistry`, plus per-investor ONCHAINID) into one flat registry.

Records arrive through **two doors**, and the pair is the architectural point, not an implementation detail:

```
   registerIdentity (AGENT)              registerIdentityWithAttestation (anyone)
   ────────────────────────              ────────────────────────────────────────
   agent transcribes an                  caller submits an EIP-712 payload
   off-chain KYC result                  signed by the claim signer
          │                                        │
          │  trust = agent's key                   │  trust = the signature
          ▼                                        ▼
        ┌──────────────────────── _register ───────────────────────┐
        │  one shared write path; both doors validate identically   │
        │  (zero addr, expiry in the future, then store + emit)     │
        └───────────────────────────────────────────────────────────┘
```

The signed door is **ERC-3643's trust model in miniature**: authorization is the signature, not the caller. It is the reason the standard bothers with ONCHAINID at all, kept even though the four-contract hierarchy is not. See [Guide 2 §2-3](./02-mathematics.md#2-the-eip-712-attestation-digest) for the digest and replay math, and the [README](../README.md#the-two-registration-paths) for the trust argument.

`isVerified` is not a stored flag read back; it is `verified && kycExpiry > now`. A verified record with a lapsed expiry reads as unverified. The registry records a claim and its provenance; it cannot validate the underlying fact, and `kycExpiry` is what stops the projection from becoming a permanent lie.

---

## 3. The compliance engine and its modules

`ModularCompliance` is the seam that makes the rule set pluggable. It holds a set of module addresses and does two things: **answer `canTransfer`** by asking every module, and **fan the token's lifecycle events** out to every module.

```solidity
EnumerableSet.AddressSet private _modules;   // O(1) add/remove/lookup, no duplicates
address private _token;                      // set once by bindToken
```

`EnumerableSet` is chosen over a plain array because it gives O(1) membership and removal and forbids duplicates, while still enumerating for the hook fan-out and for tooling via `modules()`.

Two authorization boundaries meet in this one contract and must not be confused:

| Operation | Who | Gate | Why |
|:---|:---|:---|:---|
| `addModule`, `removeModule`, `bindToken` | ISSUER | `DEFAULT_ADMIN_ROLE` | Changing the rule set is a governance action |
| `transferred`, `created`, `destroyed` | the bound token | `onlyToken` | Only the token that owns the balances may tell modules a move settled |

If lifecycle hooks were callable by anyone, an attacker could desynchronize a stateful module (holder count, lockup clocks) from the real balances and then walk through the rule. `onlyToken` is what closes that.

### Module integrity

Every module extends `AbstractComplianceModule`, which holds the engine binding as an **immutable** and gates hooks with `onlyCompliance`. Two guards, working together, make the module graph trustworthy:

- **`addModule` rejects a module not already pointing at this engine** (`ModuleNotBound`). Otherwise the engine could register a module whose `onlyCompliance` gate rejects every call the engine makes, silently never updating its state.
- **The binding is immutable.** A module cannot be re-pointed at a second engine that would corrupt the state the first accumulated. A module is cheap to redeploy, so there is no use case for rebinding.

The three modules are each one rule:

| Module | Rule | State | Checked on |
|:---|:---|:---|:---|
| `MaxHoldersModule` | ≤ N distinct holders | incremental count | recipient joining |
| `CountryRestrictionModule` | jurisdiction blocklist | blocked-country set | the **recipient** |
| `LockupModule` | holding period elapsed | per-holder clock | the **sender** |

`CountryRestriction` is a blocklist on the recipient: a restricted holder can still exit (dispose), they just cannot receive. The registry already is the allowlist. See [Guide 2 §5-6](./02-mathematics.md#5-holder-count-transitions-without-enumeration) for the holder-count and lockup arithmetic.

---

## 4. The transfer gate: a superset check

The token-level check is a **superset** of the engine's `canTransfer`. It layers the token's own cheap state checks in front of the expensive module iteration, ordered so the common rejections short-circuit first:

```
canTransfer(from, to, amount)          [ order = cheapest / most-likely-to-reject first ]
   │
   ├─ 1. not paused?                    ── SLOAD
   ├─ 2. recipient verified?            ── SLOAD (registry)
   ├─ 3. recipient not fully frozen?    ── SLOAD
   ├─ 4. sender verified?               ── SLOAD (registry)   [skipped on mint]
   ├─ 5. sender not fully frozen?       ── SLOAD              [skipped on mint]
   ├─ 6. unfrozen balance ≥ amount?     ── SLOAD              [skipped on mint]
   └─ 7. ModularCompliance.canTransfer  ── external call, iterates modules  ← most expensive, last
```

The ordering is deliberate: pause, identity, freeze and balance are single `SLOAD`s on the token itself; the module iteration is an external call across the engine to every module, so it runs last and only if everything cheaper passed.

**Both ends are checked for identity, not just the recipient.** Withdrawing an investor's identity therefore suspends their position rather than only capping it: they keep the balance but cannot move it. This matters because `removeIdentity` is what compliance reaches for when an investor may no longer hold the instrument at all, and a rule that only blocked incoming transfers would leave the sanctioned party free to sell out. The tokens survive the suspension, since losing an attestation does not extinguish title; only the issuer (`burn`) or the custodian (`forcedRecovery`) can remove them, and re-verifying releases the position.

### One implementation, two callers

The gate has a single internal status-code function, shared by:

- **`_update`** (the ERC-20 transfer path): reverts with the custom error matching the failing status.
- **`canTransfer`** (the public view): returns a bool.

They share one implementation precisely so the on-chain enforcement and the off-chain pre-check **cannot drift**. A front end calling `canTransfer` gets exactly the answer `_update` would enforce, because it is the same code. `_update` branches explicitly by shape (mint `from == 0`, burn `to == 0`, forced recovery, transfer) so each calls the correct engine hook. The recovery branch skips the gate entirely rather than relaxing it: a pause or a modular rule must not strand a compromised position on a wallet the investor no longer controls, and the checks that do matter there are performed inside `forcedRecovery` itself. The lifecycle hook still fires, so stateful modules keep tracking the movement even though their verdict on it is not consulted. This lands with Phase 4; the surface is fixed in `ISecurityToken`, and the [README](../README.md#why-a-permissioned-token-is-not-an-erc-20) covers the semantics.

---

## 5. Lifecycle hooks and state consistency

Compliance splits cleanly into two kinds of call:

```
   BEFORE a move settles              AFTER a move settles
   ─────────────────────              ─────────────────────
   canTransfer / moduleCheck          transferred / created / destroyed
   pure/view, may reject              state-mutating, cannot reject
   "is this allowed?"                 "record that it happened"
```

The `moduleCheck` calls are `view` and decide permission. The lifecycle hooks run *after* the balance update in `_update`, are state-mutating, and cannot reject: their job is to let stateful modules record what happened (a holder joined, a lockup clock started). This ordering is why the holder-count and lockup logic can read `balanceOf` to detect a `0 → positive` transition; the balance is already current when the hook fires (see [Guide 2](./02-mathematics.md#5-holder-count-transitions-without-enumeration)).

The engine fans each hook to every module in registration order:

```solidity
function transferred(address from, address to, uint256 amount) external onlyToken {
    uint256 length = _modules.length();
    for (uint256 i; i < length; ++i) {
        IComplianceModule(_modules.at(i)).moduleTransferred(from, to, amount);
    }
}
```

A stateless module (like `CountryRestriction`) simply no-ops the hooks. `canTransfer` short-circuits on the first rejecting module; the hooks do not, because every stateful module must observe every move.

---

## 6. Document anchoring

`DocumentRegistry` (designed, Phase 3) is the ERC-1643-style anchor: a mapping from a document name to `{hash, uri, timestamp}`, writable only by the ISSUER.

```
  name ──► { keccak256(content) , uri , setAt }
                     ▲                ▲
             proves WHICH bytes   says WHERE to
             are in force          fetch them
```

The hash is of the **content**, not the URI. The URI can be re-hosted freely; the hash is what a holder recomputes after fetching, to prove the exact bytes. Hashing the URI would prove only that a link did not change, which is worth nothing. The deployment script anchors [`RealEstateNote-Terms.md`](./RealEstateNote-Terms.md) this way and asserts the on-chain hash matches the file on disk (Phase 5).

---

## 7. Deployment order and the binding graph

The bindings impose a strict construction order. Each arrow is a dependency that must already exist:

```
  1. ModularCompliance(issuer)                 engine must exist first:
              │                                each module binds an engine
              ▼                                address at construction
  2. MaxHolders / Country / Lockup (compliance = engine, token = token)
              │
              ▼
  3. IdentityRegistry(issuer, agent)
              │
              ▼
  4. SecurityToken(issuer, registry, engine)
              │
              ├─► engine.addModule(each)        modules already point at engine
              ├─► engine.bindToken(token)       one-time
              └─► registry.grantRole(AGENT, token)   token retires lost wallets
                                                     during forcedRecovery
```

The last grant is the one non-obvious edge: `forcedRecovery` calls `removeIdentity` on the registry, which is `AGENT`-gated, so the **token contract itself** holds `AGENT_ROLE` on the registry. The role is held by code, not a person, and exercised only inside recovery. `Deploy.s.sol` performs this wiring and `assert`s the anchored document hash, so a mismatch between the file and the chain fails the deployment loudly (Phase 5). See [Guide 5](./05-implementation.md) for the script and the invariant suite that exercises the assembled system.

---

**See also:**
- [Guide 4: Trade-offs](./04-tradeoffs.md) - the scope decisions behind this shape
- [Guide 5: Implementation](./05-implementation.md) - deployment script, invariants, gas notes
- [README: role & permission matrix](../README.md#role-and-permission-matrix) - who can call what, and the threat model
