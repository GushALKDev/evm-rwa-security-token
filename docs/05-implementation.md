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
│       ├── LockupModule.sol                                            [built]
│       └── DividendDistributor.sol    accumulator, observer module     [built]
├── interfaces/                        all six interfaces               [built]
├── DocumentRegistry.sol               ERC-1643-style anchor            [built]
└── SecurityToken.sol                  the gated ERC-20                 [built]
```

As of the current state: **365 tests passing** (331 concrete, 22 fuzz, 12 stateful invariants; `forge test`), with 100% of branches and functions on every `src/` contract, and 100% of lines except one constant `return` line in each of the four modules (`forge coverage --report summary`, see the [README](../README.md#project-progress)).

---

## 2. Coding conventions

These conventions apply across `src/`, with the exceptions noted in the table, and are worth naming because a reviewer will see them everywhere:

| Convention | Rule |
|:---|:---|
| **Custom errors** | Every revert in `src/` is a custom error, never a string, with parameters where there is a failing value to report. Cheaper bytecode and runtime, and the parameters carry the failing values. The deployment script's sanity checks use `require` strings. |
| **CEI** | Checks-Effects-Interactions ordering where state follows an external call: `DividendDistributor.claim` records the withdrawal before transferring currency. `forcedRecovery` writes freeze state after its calls to the registry and the engine, and relies on `nonReentrant` and a trusted registry instead. |
| **Events on state change** | Every admin action and every user-facing state change emits an event (`IdentityRegistered`, `ModuleAdded`, `LockupStarted`, `LockupCleared`, ...). The distributor's correction bookkeeping in the hooks emits none of its own; it follows from the token's `Transfer` events. |
| **One-line signatures** | Function signatures stay on one line where `forge fmt` allows it; the formatter's line breaks are kept. |
| **Section banners** | `STORAGE` / `MODIFIERS` / `CONSTRUCTOR` / ... banner comments (the Solmate and forge-std style) segment every contract and interface; the `Roles` library has none. |
| **NatSpec everywhere** | Every external function and every non-obvious internal one is documented; comments explain *why*, not *what*. |
| **No em dashes** | The rule for code, NatSpec and docs. Three remain in comments in `SecurityToken.sol` (lines 183, 184 and 221). |
| **English only** | All identifiers and comments. |

Immutables use OZ v5 `_camelCase` (e.g. `_compliance`, `_token`), deliberately **not** the `SCREAMING_SNAKE_CASE` that `forge lint` suggests. This is intentional and should not be "fixed".

Formatting is `forge fmt` with the default configuration; CI (`.github/workflows/test.yml`) runs `forge fmt --check`.

---

## 3. OpenZeppelin primitives used

Everything is written from OZ v5 primitives on purpose: the goal is to demonstrate the architecture, not to redeploy T-REX.

| Primitive | Used by | For |
|:---|:---|:---|
| `AccessControl` | registry, engine, modules, token, document registry, distributor | Role-gated admin (`DEFAULT_ADMIN_ROLE`, `AGENT_ROLE`, `CUSTODIAN_ROLE`) |
| `EIP712` | `IdentityRegistry` | Domain separator + typed-data hashing for attestations |
| `ECDSA` | `IdentityRegistry` | `recover` on the attestation digest |
| `EnumerableSet` | `ModularCompliance`, `DocumentRegistry` | O(1) module set and document name index with enumeration |
| `ERC20` | `SecurityToken` | The token surface, with `_update` overridden as the gate |
| `Pausable` | `SecurityToken` | Market-wide stop |
| `ReentrancyGuard` | `SecurityToken`, `DividendDistributor` | Guard `forcedRecovery`, the one path mutating freeze state around a transfer, and the distributor's `deposit` and `claim` |
| `SafeERC20` | `DividendDistributor` | Settlement currency transfers |
| `SafeCast` | `DividendDistributor` | Checked casts between the scaled accumulator and the signed corrections |

---

## 4. Key implementation patterns

### 4.1 Shared write path for two entry points

All three registration entry points (two `registerIdentity` overloads and `registerIdentityWithAttestation`) converge on one private `_register`, so they cannot validate differently:

```solidity
function registerIdentity(...) external onlyRole(Roles.AGENT_ROLE) {
    _register(investor, country_, accredited, kycExpiry, investorId_, false);
}

function registerIdentityWithAttestation(..., bytes calldata signature) external {
    // ... nonce + signature verification ...
    _register(investor, country_, accredited, kycExpiry, investorId_, true);
}
```

The `signed` flag only feeds the event trail; every validation (zero address, expiry in the future) is identical because it lives in one place.

### 4.2 The hook gate as an abstract base

`AbstractComplianceModule` holds no rule logic. Its entire job is to bind each module to exactly one engine (immutable binding) and to restrict hooks to `onlyCompliance`. A rule module inherits it and implements only its rule:

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

`LockupModule` and `MaxHoldersModule` infer transitions from `balanceOf` *after* the move, since hooks run post-update (`DividendDistributor` works from `amount` and the token's `recovering()` flag instead). For `LockupModule` the one-line guards below are the whole rule:

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

- **Negative tests assert the specific selector.** Anything touching signatures or access control gets a bad-signature, wrong-role, reused-nonce, and expired-attestation test, each asserting the specific custom error. One test still uses a bare `vm.expectRevert()` (`test/unit/IdentityRegistry.t.sol:190`). Where a parameter is unpredictable or irrelevant (a recovered signer address, a role hash, a compliance-failure tuple), `expectPartialRevert` matches the selector without the parameters.
- **Claims are verified, not asserted.** Storage packing is checked with `forge inspect storageLayout`; revert reasons are probed before being trusted; the terms document hash is pinned in both `Deploy.s.sol` and `DeployTest`, and an edit to the file fails the deployment until both are updated.
- **Fuzz where the input space is large.** Holder-count transitions, lockup timing, and freeze arithmetic are fuzzed, not just point-tested.
- **Mocks are minimal.** `MockToken`, `MockModule` and `MockCurrency` exist only to drive the unit under test; they are test helpers, not part of the coverage target for `src/`.

Current suite: 365 tests, all green. The [testing section](./tests/README.md) catalogues every test and links each claim to the code that proves it.

```
forge test            # run the suite
forge coverage        # per-contract coverage (src/ is 100%)
forge fmt --check     # formatting gate
```

---

## 6. Deployment and anchoring

`Deploy.s.sol` (Phase 5) wires the system in the construction order the bindings demand (see [Guide 3 §7](./03-architecture.md#7-deployment-order-and-the-binding-graph)) and anchors the terms document by verified hash:

```solidity
d.termsHash = keccak256(bytes(vm.readFile(TERMS_PATH)));
d.documentRegistry.setDocument(TERMS_NAME, TERMS_URI, d.termsHash);
// ... in _verify:
(, bytes32 anchored,) = d.documentRegistry.getDocument(TERMS_NAME);
require(anchored == d.termsHash, "documents: terms hash mismatch");
require(anchored == keccak256(bytes(vm.readFile(TERMS_PATH))), "documents: terms drifted from disk");
```

The current on-disk hash of the terms document is:

```
0xc47a09b676c0dc0d2575c4dd2240d665048c0bb3fec1ba7b3c0eab1b1c49aac9
```

Any edit to the terms file changes this hash. The deployment anchors whatever is on disk at deploy time and checks that the registry stored that value; no expected hash is hardcoded in the script or its tests. A later edit therefore shows up as a mismatch between the on-chain anchor and the published file, not as a failed deployment.

---

## 7. Invariants

The handler-based invariant suite (Phase 6) drives six bounded actors through mint, burn, transfer, freeze, pause, recovery, identity withdrawal and time sequences, and asserts properties that must hold for *any* sequence of those actions. Since the review rounds the handler also drives approvals and `transferFrom` (with an unregistered spender), zero, full-balance and one-wei amounts, a country block, and dividend deposits and claims, and every revert it catches is classified as expected or unexpected. It does not add or remove modules; those rules are covered by the unit and scenario suites:

| Invariant | Statement |
|:---|:---|
| **Supply conservation** | `Σ balanceOf == totalSupply` at all times |
| **Recovery preserves supply** | `forcedRecovery` never changes `totalSupply` (pure reassignment) |
| **Frozen ≤ balance** | `frozen[a] ≤ balanceOf(a)` for every holder |
| **Holder count is exact** | the module's count equals the number of addresses with positive balance |
| **Cap respected** | holder count never exceeds `maxHolders` |
| **Unverified balances never grow** | an actor's balance stays at or below what it held when it stopped being verified (removal, recovery or an expired KYC) |
| **Lockup clock matches the position** | `lockStart(a) != 0` exactly when `balanceOf(a) != 0` |
| **Recovery keeps the lockup start** | after each recovery the destination holds the earlier of the two starts and the lost wallet none |
| **Dividends are solvent** | the distributor's currency balance covers the sum of claimable entitlements |
| **Dividends are conserved** | claimed plus claimable stays within seven wei below what was deposited, never above |
| **Blocked holders are never paid** | no claim succeeds while the claimant is fully frozen or unverified |
| **No unexpected reverts** | every revert the handler caught was one its action may legitimately produce |

These are the properties the per-unit tests cannot prove, because they are about the *composed* system under arbitrary interleavings.

---

**See also:**
- [Guide 4: Trade-offs](./04-tradeoffs.md) - why the code looks the way it does
- [Guide 6: Improvements](./06-improvements.md) - what a production build would add
- [ROADMAP](./ROADMAP.md) - live build status
