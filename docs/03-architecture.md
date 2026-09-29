# Guide 3: Architecture

**Version:** 1.0
**Prerequisites:** [Guide 2: Mathematics & Cryptography](./02-mathematics.md)
**Next:** [Guide 4: Trade-offs](./04-tradeoffs.md)

---

## Table of Contents

1. [System overview](#1-system-overview)
2. [The identity registry](#2-the-identity-registry)
3. [The compliance engine and its modules](#3-the-compliance-engine-and-its-modules)
4. [The transfer gate: a superset check](#4-the-transfer-gate-a-superset-check)
5. [Lifecycle hooks and state consistency](#5-lifecycle-hooks-and-state-consistency)
6. [Document anchoring](#6-document-anchoring)
7. [Deployment order and the binding graph](#7-deployment-order-and-the-binding-graph)

---

> This guide describes how the parts wire together. The *rationale* for what was scoped out (ONCHAINID, partitions, proxies) is argued in [Guide 4](./04-tradeoffs.md#2-scope-decisions) and the access-control threat model in [Guide 7](./07-security.md); neither is repeated here.

---

## 1. System overview

Eight contracts (plus shared `Roles` and an abstract module base), all built and tested: the token, `IdentityRegistry`, `ModularCompliance`, `DocumentRegistry` and four modules (`MaxHolders`, `CountryRestriction`, `Lockup` and `DividendDistributor`). `Deploy.s.sol` deploys seven of them; `DividendDistributor` is not part of the script and is registered separately. The [README](../README.md#architecture) carries the top-level component diagram; this guide goes seam by seam.

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
                                     (plus DividendDistributor, an observer
                                      module registered the same way)
                              ┌──────────────────┐
        ISSUER ──────────────►│ DocumentRegistry │  (hash + URI per name)
                              └──────────────────┘
```

Two invariants define the shape:

1. **The token references the engine, never the modules.** The rule set is pluggable at the engine, so it changes by governance action, not token redeploy. A stateful module registered on a live token would start with empty state and miss every move made while it was not registered. The engine enforces this: `addModule` asks each module `canComplianceBind` and refuses the holder cap and the lockup once the token has supply, and any stateful module (those two and the dividend distributor) the second time it is offered. See [Attaching stateful modules](#attaching-stateful-modules).
2. **Every module answers to exactly one engine, and every engine to exactly one token.** Both bindings are set once and never rebindable. This is what keeps stateful rules from being corrupted by a second caller. A module that reads balances must also read the engine's own token: `addModule` and `bindToken` reject a mismatch (`ModuleTokenMismatch`).

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

- **`addModule` rejects a module not already pointing at this engine** (`ModuleNotBound`). Otherwise the engine could register a module whose `onlyCompliance` gate rejects every hook call the engine makes, which would revert every mint, burn and transfer.
- **At most 25 modules** (`MAX_MODULES`, the T-REX limit). Every transfer iterates the modules in the check and again in the hooks, so the cap bounds that loop; `addModule` reverts with `ModuleLimitReached` beyond it.
- **The binding is immutable.** A module cannot be re-pointed at a second engine that would corrupt the state the first accumulated. A module is cheap to redeploy, so there is no use case for rebinding.

The three rule modules are each one rule. A fourth module, `DividendDistributor`, never vetoes (its `moduleCheck` always returns true) and uses the hooks only to account income:

| Module | Rule | State | Checked on |
|:---|:---|:---|:---|
| `MaxHoldersModule` | ≤ N distinct holders | incremental count | recipient joining |
| `CountryRestrictionModule` | jurisdiction blocklist | blocked-country set | the **recipient** |
| `LockupModule` | holding period elapsed | per-holder clock | the **sender** |

`CountryRestriction` is a blocklist on the recipient: a restricted holder can still exit (dispose), they just cannot receive. The registry already is the allowlist. See [Guide 2 §5-6](./02-mathematics.md#5-holder-count-transitions-without-enumeration) for the holder-count and lockup arithmetic.

### The dividend distributor: a module, not a rule

The module interface has two halves: `moduleCheck`, which decides whether a transfer is allowed, and the lifecycle hooks, which observe that one settled. The three rule modules use both. The distributor implements `moduleCheck` as an unconditional `true` and puts all of its logic in the hooks, using the fan-out as an on-chain event bus and giving up the power of veto. Withholding income from a sanctioned holder is a matter for the token's freeze and identity controls, not the transfer gate: `claim` reverts while the holder is fully frozen or not verified (an expired KYC counts), the entitlement keeps accruing, and it becomes claimable once the block is lifted. A partial freeze does not block a claim, since it immobilises tokens, not the holder.

That choice is why income distribution required no change to `SecurityToken` beyond a single view, and why it can be registered on a live deployment with `addModule`. It also has a limit worth stating: `moduleTransferred(from, to, amount)` is byte-identical for a sale and for a forced recovery, and those mean opposite things for anything that accrues value to a holder. The distributor therefore has to ask the token which it is (`recovering()`), making it one of the two modules that depend on the token being a `SecurityToken` rather than any ERC-20 (`LockupModule` asks the same question, see below), and it reads the token's freeze state and identity registry in `claim`. A system with several value-accruing modules would want the transfer kind passed through the hook itself.

### Attaching stateful modules

The engine refuses to attach a stateful module it cannot keep in step. A module only sees the movements that happen while it is registered, and nothing reconciles its state with existing balances, so the engine asks the module first (`canComplianceBind`, the T-REX shape) and reverts with `ModuleCannotBind` when it says no:

- `MaxHoldersModule` and `LockupModule` refuse while the token has supply. A holder count added late would start at zero and make the first existing holder's exit underflow; a lockup added late would have no clock for existing holders.
- Every stateful module (those two and `DividendDistributor`) refuses a second attach after a removal, because it missed every movement made while it was out.
- `DividendDistributor` may join a live token once: its accumulator starts at zero, so balances that predate it simply earn from the first deposit it sees. After a removal it rejects `deposit` (`DistributorNotAttached`) and keeps paying what accrued while it was attached.
- `CountryRestrictionModule` is stateless (`isPlugAndPlay`) and can be removed and attached again at any time.
- A module that reads balances must read the engine's own token: `addModule` and `bindToken` both reject a mismatch (`ModuleTokenMismatch`).

Rules can change without redeploying the token; a stateful rule has to be in place before the balances it tracks. Adding one to an issued token means deploying the token again with it.

---

## 4. The transfer gate: a superset check

The token-level check is a **superset** of the engine's `canTransfer`. It layers the token's own cheap state checks in front of the expensive module iteration, ordered so the common rejections short-circuit first:

```
canTransfer(from, to, amount)          [ order = cheapest / most-likely-to-reject first ]
   │
   ├─ 1. not paused?                    ── SLOAD
   ├─ 2. recipient verified?            ── registry call
   ├─ 3. recipient not fully frozen?    ── SLOAD
   ├─ 4. sender verified?               ── registry call      [skipped on mint]
   ├─ 5. sender not fully frozen?       ── SLOAD              [skipped on mint]
   ├─ 6. unfrozen balance ≥ amount?     ── SLOAD              [skipped on mint]
   └─ 7. ModularCompliance.canTransfer  ── external call, iterates modules  ← most expensive, last
```

The ordering is deliberate: pause, freeze and balance are storage reads on the token itself, and identity is one external view call to the registry per party (one storage slot, see [Guide 2 §4](./02-mathematics.md#4-storage-packing-of-the-identity-record)); the module iteration is an external call to the engine plus one call per module, so it runs last and only if everything cheaper passed. A burn runs only step 1: it skips identity, freeze and the module check, and `burn` itself reconciles the frozen portion. Forced recovery skips all seven steps.

**Both ends are checked for identity, not just the recipient** (the ends are the sender and the recipient; the `transferFrom` spender is not checked). Withdrawing an investor's identity therefore suspends their position rather than only capping it: they keep the balance but cannot move it. This matters because `removeIdentity` is what compliance reaches for when an investor may no longer hold the instrument at all, and a rule that only blocked incoming transfers would leave the sanctioned party free to sell out. The tokens survive the suspension, since losing an attestation does not extinguish title; only the issuer (`burn`) or the custodian (`forcedRecovery`) can remove them, and re-verifying releases the position. Recovery works on a suspended wallet because removal keeps its `investorId`. With `DividendDistributor` registered, a suspended or fully frozen holder cannot claim either; the income keeps accruing and is released with the position.

### One implementation, two callers

The gate has a single internal status-code function, shared by:

- **`_update`** (the ERC-20 transfer path): reverts with the custom error matching the failing status.
- **`canTransfer`** (the public view): returns a bool.

They share one implementation precisely so the on-chain enforcement and the off-chain pre-check **cannot drift** for ordinary transfers and mints. A front end calling `canTransfer` gets exactly the answer `_update` would enforce for those, because it is the same code. Burn and forced recovery do not pass through the gate, so `canTransfer` is not a pre-check for those two shapes. `_update` branches explicitly by shape (mint `from == 0`, burn `to == 0`, forced recovery, transfer) so each calls the correct engine hook. The recovery branch skips the gate entirely rather than relaxing it: a pause or a modular rule must not strand a compromised position on a wallet the investor no longer controls, and the checks that do matter there are performed inside `forcedRecovery` itself. The lifecycle hook still fires, so stateful modules keep tracking the movement even though their verdict on it is not consulted. Two modules cannot read a recovery from the hook arguments alone, because they look like a sale: `LockupModule` and `DividendDistributor` ask the token `recovering()` and move the lockup start and the unclaimed income with the position instead of treating the destination as a new buyer. The [README](../README.md#why-a-permissioned-token-is-not-an-erc-20) covers the semantics.

### How `_update` branches

Every mint, burn and transfer in OZ v5 funnels through `_update`, so the gate lives there and no ERC-20 entrypoint can go around it. It branches by shape, and each branch fires the engine hook matching what actually happened:

```
_update(from, to, amount)
   │
   ├─ paused && !_recovering ─────────────────► revert EnforcedPause
   │
   ├─ from == 0   MINT      →  _checkTransfer → move → compliance.created(to)
   ├─ to   == 0   BURN      →  (no gate)      → move → compliance.destroyed(from)
   ├─ _recovering RECOVERY  →  (gate skipped) → move → compliance.transferred(...)
   └─ otherwise   TRANSFER  →  _checkTransfer → move → compliance.transferred(...)
```

The `canTransfer` view checks the pause itself before running the same status-code function. The two non-obvious branches:

- **Burn runs no gate.** The issuer-facing `burn` has already reconciled the frozen portion, and there is no recipient to verify. A freeze must not shelter tokens from the issuer retiring a position under a court order or redemption.
- **Recovery skips the gate entirely** rather than relaxing it, because every check it would run is either already checked inside `forcedRecovery` (destination verified, same `investorId`, sender's freeze cleared) or is the wrong question: an unexpired lockup or an exhausted holder cap must not strand a compromised position. The lifecycle hook still fires, so stateful modules keep tracking the move even though their verdict on it is not consulted.

### The forced-recovery sequence

The one flow that touches all three contracts, and the one with the largest blast radius:

```
CUSTODIAN ──► forcedRecovery(lostWallet, newWallet)          [nonReentrant]
   │
   ├─ 1. reject if same wallet
   ├─ 2. registry.isVerified(newWallet)          destination must be onboarded
   ├─ 3. investorId(lost) == investorId(new)     both wallets, one investor
   ├─ 4. balance != 0
   │
   ├─ 5. snapshot freeze state (partial amount + full flag)
   ├─ 6. clear lost wallet's freeze state        emits TokensUnfrozen / AddressFrozen(false)
   ├─ 7. registry.removeIdentity(lostWallet)     skipped if the agent already removed it
   │
   ├─ 8. _recovering = true → _transfer → _recovering = false
   │
   ├─ 9. re-apply the snapshotted freeze on newWallet
   └─ 10. emit RecoverySuccess(lost, new, amount, frozen, wasFullyFrozen)
```

Steps 5-9 are why recovery relocates a position without laundering a hold: a frozen lot arrives frozen at its new address, and the event log shows both halves. During step 8 the lifecycle hook fires, and the two modules that hold per-wallet state ask the token whether a recovery is in progress: `LockupModule` moves the lockup start instead of starting a fresh clock (the destination keeps the earlier of the two starts), and `DividendDistributor` moves the unclaimed income. Step 3 works on a wallet the agent already removed, because removal keeps the `investorId`. Step 3 is what keeps a compromised custodian key from recovering into an arbitrary verified wallet; see the [threat model](./07-security.md#3-recovery-abuse-constrained-and-auditable-not-prevented) for how far that constraint actually goes.

---

## 5. Lifecycle hooks and state consistency

Compliance splits cleanly into two kinds of call:

```
   BEFORE a move settles              AFTER a move settles
   ─────────────────────              ─────────────────────
   canTransfer / moduleCheck          transferred / created / destroyed
   pure/view, may reject              state-mutating, no verdict
   "is this allowed?"                 "record that it happened"
```

The `moduleCheck` calls are `view` and decide permission. The lifecycle hooks run *after* the balance update in `_update`, are state-mutating, and return no verdict (a hook that reverts still aborts the move, as `MaxHoldersModule` does on an arithmetic underflow): their job is to let stateful modules record what happened (a holder joined, a lockup clock started). This ordering is why the holder-count and lockup logic can read `balanceOf` to detect a `0 → positive` transition; the balance is already current when the hook fires (see [Guide 2](./02-mathematics.md#5-holder-count-transitions-without-enumeration)).

The engine fans each hook to every module in set order (registration order until the first `removeModule`, which moves the last module into the removed slot):

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

`DocumentRegistry` is the ERC-1643-style anchor: a mapping from a document name to `{uri, contentHash, lastModified}`, writable only by the ISSUER.

```
  name ──► { keccak256(content) , uri , lastModified }
                     ▲                ▲
             proves WHICH bytes   says WHERE to
             are in force          fetch them
```

The hash is of the **content**, not the URI. The URI can be re-hosted freely; the hash is what a holder recomputes after fetching, to prove the exact bytes. Hashing the URI would prove only that a link did not change, which is worth nothing. The deployment script anchors [`RealEstateNote-Terms.md`](./RealEstateNote-Terms.md) this way: it hashes the file as read at deployment and `require`s that the on-chain hash equals that value. The registry itself stores whatever hash the issuer supplies; it cannot check it against the content.

---

## 7. Deployment order and the binding graph

The bindings impose a partial order: the engine and the registry (in either order) before the token, and the token before the modules that hold it (`CountryRestriction` only needs the engine and the registry). The script uses this linearization:

```
  1. ModularCompliance(issuer)                 engine must exist first:
              │                                each module binds an engine
              ▼                                address at construction
  2. IdentityRegistry(issuer, agent)
              │
              ▼
  3. SecurityToken(issuer, registry, engine)   both are constructor args,
              │                                there is no setter for either
              ▼
  4. MaxHolders(engine, token, ...)            MaxHolders and Lockup hold the
     Lockup(engine, token, ...)                token as an immutable, so they
     CountryRestriction(engine, registry, ...) cannot precede it
              │
              ├─► engine.addModule(each)        modules already point at engine
              ├─► engine.bindToken(token)       one-time
              ├─► registry.grantRole(AGENT, token)   token de-registers lost
              │                                      wallets during forcedRecovery
              ├─► token.grantRole(CUSTODIAN, custodian)
              ├─► token.grantRole(AGENT, agent)
              └─► DocumentRegistry(issuer) + setDocument(TERMS, uri, hash)
```

The order is worth stating because the intuitive one is wrong. "Engine, modules, registry, token" is not satisfiable: two of the three rule modules (and `DividendDistributor`) take the token address as an `immutable`, and the token takes the registry and the engine as constructor arguments with no setter for either. The token must therefore be constructed after the registry and the engine, but before the modules that watch its balances.

The last grant is the one non-obvious edge: `forcedRecovery` calls `removeIdentity` on the registry, which is `AGENT`-gated, so the **token contract itself** holds `AGENT_ROLE` on the registry. The role is held by code, not a person. It would also permit both `registerIdentity` overloads, but the token's code calls only `removeIdentity`, and only inside recovery. `Deploy.s.sol` performs this wiring and reverts with `TermsHashMismatch` unless the terms file hashes to the pinned `TERMS_HASH`, so a drifted document fails the deployment; it then checks that the registry stored that hash. Its limitations: the wiring calls are admin-gated, so the executing account must be the issuer and a real deployment needs a deploy-then-handover step; the three operator roles default to the broadcasting account when the `RWA_ISSUER`, `RWA_AGENT` and `RWA_CUSTODIAN` environment variables are unset; and `DividendDistributor` is not deployed. See [Guide 5](./05-implementation.md) for the script and the invariant suite that exercises the assembled system.

`Deploy.s.sol` pins the terms hash in `TERMS_HASH` and `DeployTest` pins the same value independently; `test_deploy_revertsWhenTermsDrift` shows a drifted document failing the deployment. Amending the terms before a deployment therefore means changing the file and both constants on purpose; after deployment, it goes through `setDocument` on the registry. The script wires the three rule modules only (`_verify` requires exactly three), and `test_run_defaultsEveryRoleToTheBroadcaster` and `test_run_readsOperatorsFromTheEnvironment` run `run()` end to end with the operator variables unset and set.

---

**See also:**
- [Guide 4: Trade-offs](./04-tradeoffs.md) - the scope decisions behind this shape
- [Guide 5: Implementation](./05-implementation.md) - deployment script, invariants, gas notes
- [Guide 7: Security](./07-security.md) - who can call what, and the threat model
