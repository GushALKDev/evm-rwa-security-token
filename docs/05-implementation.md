# 🛠️ Guide 5: Implementation

**Version:** 1.0
**Prerequisites:** [Guide 3: Architecture](./03-architecture.md)
**Next:** [Guide 6: Improvements](./06-improvements.md)

---

## 📋 Table of Contents

1. [Build order and status](#1-build-order-and-status)
2. [Coding conventions](#2-coding-conventions)
3. [OpenZeppelin primitives used](#3-openzeppelin-primitives-used)
4. [Key implementation patterns](#4-key-implementation-patterns)
5. [Testing strategy](#5-testing-strategy)
6. [Deployment and anchoring](#6-deployment-and-anchoring)
7. [Invariants](#7-invariants)

---

## 1. Build order and status

The project is built one contract per unit, each with its own tests, reviewed and committed before the next. The order is a dependency order (identity and compliance exist before the token that calls them). Live status is tracked in the [ROADMAP](./ROADMAP.md).

```
src/
├── Roles.sol                          library of role constants        [built]
├── identity/
│   └── IdentityRegistry.sol           KYC projection, EIP-712          [built]
├── compliance/
│   ├── ModularCompliance.sol          the engine                       [built]
│   └── modules/
│       ├── AbstractComplianceModule.sol   binding + hook gate          [built]
│       ├── MaxHoldersModule.sol                                        [built]
│       ├── CountryRestrictionModule.sol                                [built]
│       └── LockupModule.sol                                            [built]
├── interfaces/                        all five interfaces              [built]
├── DocumentRegistry.sol               ERC-1643-style anchor            [designed]
└── SecurityToken.sol                  the gated ERC-20                 [designed]
```

As of the current state: **248 tests passing, 100% line/statement/branch/function coverage on every `src/` contract.**

---

## 2. Coding conventions

These are enforced consistently across the codebase and are worth naming, because a reviewer will see them everywhere:

| Convention | Rule |
|:---|:---|
| **Custom errors** | Every revert is a custom error with parameters, never a string. Cheaper bytecode and runtime, and the parameters carry the failing values. |
| **CEI** | Checks-Effects-Interactions ordering. The nonce consumption before signature check is a pointed example (effect before the external `recover`). |
| **Events on state change** | Every state mutation emits an event (`IdentityRegistered`, `ModuleAdded`, `LockupStarted`, `LockupCleared`, ...). |
| **One-line signatures** | Function signatures stay on one line unless genuinely excessive. |
| **OZ header blocks** | The `STORAGE` / `MODIFIERS` / `CONSTRUCTOR` / ... banner comments segment every contract. |
| **NatSpec everywhere** | Every external function and every non-obvious internal one is documented; comments explain *why*, not *what*. |
| **No em dashes** | Anywhere: code, NatSpec, docs. |
| **English only** | All identifiers and comments. |

Immutables use OZ v5 `_camelCase` (e.g. `_compliance`, `_token`), deliberately **not** the `SCREAMING_SNAKE_CASE` that `forge lint` suggests. This is intentional and should not be "fixed".

Formatting is `forge fmt`, enforced in CI.

---

## 3. OpenZeppelin primitives used

Everything is written from OZ v5 primitives on purpose: the goal is to demonstrate the architecture, not to redeploy T-REX.

| Primitive | Used by | For |
|:---|:---|:---|
| `AccessControl` | registry, engine, modules, token | Role-gated admin (`DEFAULT_ADMIN_ROLE`, `AGENT_ROLE`, `CUSTODIAN_ROLE`) |
| `EIP712` | `IdentityRegistry` | Domain separator + typed-data hashing for attestations |
| `ECDSA` | `IdentityRegistry` | `recover` on the attestation digest |
| `EnumerableSet` | `ModularCompliance` | O(1) module set with enumeration |
| `ERC20` | `SecurityToken` (designed) | The token surface, with `_update` overridden as the gate |
| `Pausable` | `SecurityToken` (designed) | Market-wide stop |
| `ReentrancyGuard` | `SecurityToken`, dividends (designed) | Guard the recovery / claim paths |

---

## 4. Key implementation patterns

### 4.1 Shared write path for two entry points

Both registration doors converge on one private `_register`, so they cannot validate differently:

```solidity
function registerIdentity(...) external onlyRole(Roles.AGENT_ROLE) {
    _register(investor, country_, accredited, kycExpiry, false);
}

function registerIdentityWithAttestation(..., bytes calldata signature) external {
    // ... nonce + signature verification ...
    _register(investor, country_, accredited, kycExpiry, true);
}
```

The `signed` flag only feeds the event trail; every validation (zero address, expiry in the future) is identical because it lives in one place.

### 4.2 The hook gate as an abstract base

`AbstractComplianceModule` holds no rule logic. Its entire job is to guarantee each module answers to exactly one engine (immutable binding) and that hooks are `onlyCompliance`. A rule module inherits it and implements only its rule:

```solidity
contract LockupModule is AbstractComplianceModule, AccessControl {
    constructor(address compliance_, ...) AbstractComplianceModule(compliance_) { ... }

    function moduleTransferred(address from, address to, uint256 amount) external onlyCompliance {
        _startClockIfNew(to, amount);
        _clearClockIfExited(from);
    }
}
```

### 4.3 Post-move balance inspection

Stateful modules infer transitions from `balanceOf` *after* the move, since hooks run post-update. The one-line guards are the whole security surface:

```solidity
function _startClockIfNew(address to, uint256 amount) private {
    if (amount == 0) return;
    if (_token.balanceOf(to) != amount) return;   // not a 0 → positive transition
    if (_lockStart[to] != 0) return;              // ← anti-griefing: never overwrite
    // ... start clock, emit ...
}
```

### 4.4 Short-circuit view, exhaustive hooks

`canTransfer` returns on the first rejecting module (no reason to evaluate the rest). The lifecycle hooks iterate *every* module unconditionally, because each stateful module must observe every move. Same set, two iteration disciplines.

---

## 5. Testing strategy

The project runs a strict review-gated per-unit loop: implement one contract, test it to green with full coverage, then stop for review before committing. The tests reflect a few firm rules:

- **Negative tests assert the specific selector.** Anything touching signatures or access control gets a bad-signature, wrong-role, reused-nonce, and expired-attestation test, each asserting the exact custom error, never a bare `vm.expectRevert()`. Where the recovered address is unpredictable (signature replay), `expectPartialRevert` matches the selector without the parameters.
- **Claims are verified, not asserted.** Storage packing is checked with `forge inspect storageLayout`; revert reasons are probed before being trusted; the anchored document hash is recomputed after any edit to the terms file.
- **Fuzz where the input space is large.** Holder-count transitions, lockup timing, and freeze arithmetic are fuzzed, not just point-tested.
- **Mocks are minimal.** `MockToken` and `MockModule` exist only to drive the unit under test; they are test helpers, not part of the coverage target for `src/`.

Current suite: 248 tests, all green. The [testing section](./tests/README.md) catalogues every test and links each claim to the code that proves it.

```
forge test            # run the suite
forge coverage        # per-contract coverage (src/ is 100%)
forge fmt --check     # formatting gate
```

---

## 6. Deployment and anchoring

`Deploy.s.sol` (Phase 5) wires the system in the construction order the bindings demand (see [Guide 3 §7](./03-architecture.md#7-deployment-order-and-the-binding-graph)) and anchors the terms document by verified hash:

```solidity
bytes32 onChain  = documentRegistry.getDocument("terms").hash;
bytes32 onDisk   = keccak256(vm.readFile("docs/RealEstateNote-Terms.md"));
assert(onChain == onDisk);   // deployment fails loudly if they disagree
```

The current on-disk hash of the terms document is:

```
0x30536762f053a4d373521894dfaf049104505d7eb476717273feb537c88847a6
```

Any edit to the terms file changes this hash, which is the point: the anchor and the document move together or the deployment aborts.

---

## 7. Invariants

The handler-based invariant suite (Phase 6) drives bounded actors through mint/transfer/freeze/recover sequences and asserts properties that must hold for *any* sequence:

| Invariant | Statement |
|:---|:---|
| **Supply conservation** | `Σ balanceOf == totalSupply` at all times |
| **Recovery preserves supply** | `forcedRecovery` never changes `totalSupply` (pure reassignment) |
| **Frozen ≤ balance** | `frozen[a] ≤ balanceOf(a)` for every holder |
| **Holder count is exact** | the module's count equals the number of addresses with positive balance |
| **Cap respected** | holder count never exceeds `maxHolders` |
| **Verified recipients only** | no positive balance is ever held by an unverified, un-recovered address |

These are the properties the per-unit tests cannot prove, because they are about the *composed* system under arbitrary interleavings.

---

**See also:**
- [Guide 4: Trade-offs](./04-tradeoffs.md) - why the code looks the way it does
- [Guide 6: Improvements](./06-improvements.md) - what a production build would add
- [ROADMAP](./ROADMAP.md) - live build status
