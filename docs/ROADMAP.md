# 🗺️ ROADMAP: EVM RWA Security Token

**Version:** 1.0
**Purpose:** Ordered implementation guide and progress tracker

---

## 📋 How to use this document

- **[ ]** = Pending
- **[~]** = In progress
- **[x]** = Completed
- **[!]** = Blocked / Requires decision

The build order is a dependency order, not a preference. Each unit is one contract with its own unit and fuzz tests, reviewed and committed before the next begins. The identity and compliance layers exist before the token because the token's transfer gate calls into both; the deployment script and the scenario/invariant suites come last because they exercise the finished system.

---

## 📊 Progress Summary

| Phase     | Name                          | Items  | Completed | Progress |
| :-------- | :---------------------------- | :----- | :-------- | :------- |
| 0         | Foundations                   | 3      | 3         | 100%     |
| 1         | Identity Layer                | 2      | 2         | 100%     |
| 2         | Compliance Layer              | 6      | 6         | 100%     |
| 3         | Document Anchoring            | 2      | 2         | 100%     |
| 4         | The Security Token            | 7      | 0         | 0%       |
| 5         | Deployment & Anchoring        | 3      | 0         | 0%       |
| 6         | Scenario & Invariant Testing  | 4      | 0         | 0%       |
| 7         | Documentation & Threat Model  | 4      | 1         | 25%      |
| 8         | Stretch: Dividends            | 4      | 0         | 0%       |
| **TOTAL** |                               | **31** | **20**    | **65%**  |

> The percentage tracks units of implementation, not lines of code. The identity and compliance layers are the architecturally substantive part of an ERC-3643 subset, which is why the project is further along than a contract count alone would suggest.

---

## Phase 0: Foundations

> **Objective:** Establish the shared vocabulary the whole system derives from: interfaces, roles, and the legal instrument being tokenized.

- [x] **0.1** Interfaces for every unit (`IIdentityRegistry`, `IComplianceModule`, `IModularCompliance`, `IDocumentRegistry`, `ISecurityToken`)
- [x] **0.2** `Roles.sol` shared role constants (`AGENT_ROLE`, `CUSTODIAN_ROLE`; ISSUER is `DEFAULT_ADMIN_ROLE`)
- [x] **0.3** Sample terms document (`docs/RealEstateNote-Terms.md`), the off-chain instrument the token represents

**Deliverables:**

- Every contract's external surface fixed before implementation, so units can be built and reviewed against a stable contract.
- Role identifiers defined once, so a grant on one contract always matches a check on another.

**Reference:** [03-architecture.md](./03-architecture.md), [01-fundamentals.md](./01-fundamentals.md)

---

## Phase 1: Identity Layer

> **Objective:** Answer "may this address hold the token, and is that still true?" as an on-chain projection of an off-chain KYC process.
>
> **Dependencies:** Phase 0

- [x] **1.1** `IdentityRegistry.sol`
    - [x] 1.1.1 Packed `Identity` record (`verified`, `accredited`, `country`, `kycExpiry`) in a single slot
    - [x] 1.1.2 `registerIdentity` (AGENT writes an off-chain KYC result directly)
    - [x] 1.1.3 `registerIdentityWithAttestation` (permissionless submit, EIP-712 signed by the claim signer)
    - [x] 1.1.4 Per-investor nonce consumed before signature verification (closes in-window replay)
    - [x] 1.1.5 `isVerified` gated on `kycExpiry` (a stale attestation is not a verified one)
    - [x] 1.1.6 Shared `_register` write path so both doors validate identically
- [x] **1.2** Unit + fuzz tests (100% coverage; bad signature, reused nonce, expired attestation, wrong role, cross-domain replay)

**Deliverables:**

- Two registration paths modeling two trust assumptions: trust the agent's key, or trust the claim signer's signature.
- Replay closed on three axes: chain/deployment (domain separator), time (expiry), and in-window re-registration (nonce).

**Reference:** [02-mathematics.md](./02-mathematics.md) (EIP-712 digest), [03-architecture.md](./03-architecture.md)

---

## Phase 2: Compliance Layer

> **Objective:** Make the rule set pluggable. The token holds one engine; the engine composes rule modules and fans lifecycle events out to them.
>
> **Dependencies:** Phase 1

- [x] **2.1** `AbstractComplianceModule.sol` (immutable engine binding, `onlyCompliance` hook gate)
- [x] **2.2** `MaxHoldersModule.sol` (incremental holder count in hooks, replacement-at-cap allowed)
- [x] **2.3** `CountryRestrictionModule.sol` (recipient-side jurisdiction blocklist)
- [x] **2.4** `LockupModule.sol` (holding period from initial acquisition, dust-relock immune)
- [x] **2.5** `ModularCompliance.sol` (EnumerableSet of modules, `canTransfer` view, hook fan-out, `bindToken` once)
- [x] **2.6** Unit + fuzz tests for each (100% coverage on all five contracts; 138 tests total in the suite)

**Deliverables:**

- A rule set that changes by governance action (add/remove a module), never by redeploying the token.
- Stateful rules (holder count, lockup clocks) whose state can only be mutated by the bound token, through the engine.

**Reference:** [02-mathematics.md](./02-mathematics.md) (holder-count transitions, lockup clock), [04-tradeoffs.md](./04-tradeoffs.md) (lockup model choice)

---

## Phase 3: Document Anchoring

> **Objective:** Bind the legal terms to the token by content hash, so a silent amendment is evident on-chain.
>
> **Dependencies:** Phase 0

- [x] **3.1** `DocumentRegistry.sol` (ERC-1643-style: `setDocument`/`removeDocument`, `{hash, uri, timestamp}` per name, ISSUER-gated)
    - [x] 3.1.1 `EnumerableSet.Bytes32Set` name index (O(1) add/remove/membership, enumerable for `getAllDocuments`)
    - [x] 3.1.2 `setDocument` upserts: a new name joins the index, a re-anchor overwrites the record in place
    - [x] 3.1.3 `name` is a `bytes32` label (`bytes32("TERMS")`), human readable off-chain rather than an opaque hash
    - [x] 3.1.4 Amendment history lives in the `DocumentUpdated` event log, not in per-version storage
- [x] **3.2** Unit + fuzz tests (100% coverage; overwrite semantics, removal, access control)

**Deliverables:**

- A `name → {hash, uri, timestamp}` anchor where the hash is of the content, not the URI.
- The seam the deployment script uses to publish the terms hash on-chain.

**Reference:** [03-architecture.md](./03-architecture.md) (on-chain/off-chain boundary)

---

## Phase 4: The Security Token

> **Objective:** The centerpiece. An ERC-20 in shape whose every movement is gated by identity and compliance, plus the issuer powers a regulated instrument requires.
>
> **Dependencies:** Phases 1, 2, 3

- [ ] **4.1** `SecurityToken.sol` skeleton (OZ ERC20 + AccessControl + Pausable + ReentrancyGuard)
- [ ] **4.2** Transfer gate: one internal status-code function shared by `_update` (reverts) and `canTransfer` (bool), so they cannot drift
- [ ] **4.3** Three explicit `_update` branches (mint, burn, transfer), each calling the matching engine hook
- [ ] **4.4** Freeze controls: full freeze (`setAddressFrozen`) and partial freeze (`freezePartialTokens`/`unfreezePartialTokens`)
- [ ] **4.5** `forcedRecovery` (CUSTODIAN): move full balance to a verified wallet, carry over both freeze states, retire the lost wallet, preserve supply
- [ ] **4.6** `mint`/`burn` (ISSUER); burn eats frozen balance if needed (issuer retiring a position outranks a freeze)
- [ ] **4.7** Unit + fuzz tests (100% coverage; every revert branch, freeze interactions, recovery freeze-carry)

**Deliverables:**

- A transfer that reverts at the compliance boundary rather than moving illegally.
- Recovery that cannot launder a freeze or change total supply.

**Reference:** [03-architecture.md](./03-architecture.md) (transfer gate), [05-implementation.md](./05-implementation.md), [04-tradeoffs.md](./04-tradeoffs.md) (recovery blast radius)

---

## Phase 5: Deployment & Anchoring

> **Objective:** Wire the system together in the correct order and anchor the terms document by verified hash.
>
> **Dependencies:** Phase 4

- [ ] **5.1** `Deploy.s.sol`: engine → modules → registry → token, then `addModule`, `bindToken`, grant the token `AGENT_ROLE` on the registry
- [ ] **5.2** Anchor `docs/RealEstateNote-Terms.md` via `vm.readFile` + `keccak256`, and `assert` the on-chain hash matches
- [ ] **5.3** Deployment sanity checks (roles granted, engine bound, document anchored)

**Deliverables:**

- A one-command deployment that fails loudly if the anchored hash and the file on disk disagree.

**Reference:** [05-implementation.md](./05-implementation.md) (deployment order)

---

## Phase 6: Scenario & Invariant Testing

> **Objective:** Prove system-level properties the per-unit tests cannot: that the composed system holds its invariants under arbitrary sequences.
>
> **Dependencies:** Phase 4

- [ ] **6.1** Scenario tests (onboard → mint → transfer under lockup → freeze → recover, end to end)
- [ ] **6.2** Handler-based invariant suite (bounded actors driving mint/transfer/freeze/recover)
- [ ] **6.3** Invariants: total supply conserved across recovery; sum of balances == totalSupply; frozen ≤ balance per holder; holder count matches live holders
- [ ] **6.4** Coverage report across the full system

**Deliverables:**

- Properties that must never break, checked against random sequences, not just hand-picked cases.

**Reference:** [05-implementation.md](./05-implementation.md) (invariants)

---

## Phase 7: Documentation & Threat Model

> **Objective:** The written argument. For a portfolio piece the reasoning is graded as heavily as the code.
>
> **Dependencies:** Ongoing

- [x] **7.1** README (asset, scoping decisions, on/off-chain boundary, role matrix, access-control threat model)
- [ ] **7.2** Architecture diagram reflecting the finished code
- [ ] **7.3** Threat model against the finished implementation (compliance bypass, reentrancy, recovery abuse)
- [ ] **7.4** These technical guides (`docs/01`-`06`) kept in step with the code

**Deliverables:**

- A reader can reconstruct why each scope decision was made and what security property it bought.

**Reference:** [README](../README.md), all guides.

---

## Phase 8: Stretch - Dividend Distribution

> **Objective:** Only if the core is complete and tested, and only after explicit confirmation. Distribute income to holders without iterating the holder set.
>
> **Dependencies:** Phase 4

- [ ] **8.1** `DividendDistributor.sol` (accumulator pattern: dividends-per-share, per-account correction)
- [ ] **8.2** Correction applied in the token's transfer hook so a transfer cannot double-claim
- [ ] **8.3** Pull-pattern claim with a reentrancy guard
- [ ] **8.4** Unit + fuzz tests (rounding dust bounded, conservation of distributed funds)

**Deliverables:**

- O(1) distribution regardless of holder count; no snapshot, no `ERC20Votes`.

**Reference:** [06-improvements.md](./06-improvements.md)

---

## 📝 Changelog

| Date       | Changes                 |
| :--------- | :---------------------- |
| 2026-07-24 | Phase 3 complete: `DocumentRegistry` (ERC-1643 subset, `EnumerableSet.Bytes32Set` name index, `setDocument` upsert, `bytes32` readable names, ISSUER-gated). 20 tests, 158 total, 100% coverage on all `src/` contracts |
| 2026-07-19 | Phase 2 complete: `ModularCompliance` engine (EnumerableSet of modules, `canTransfer` view, lifecycle hook fan-out, `bindToken` once, `onlyToken`/`DEFAULT_ADMIN_ROLE` split). 27 engine tests, 138 total, 100% coverage on all `src/` contracts. Docs and ROADMAP added |
| 2026-07-16 | Phase 2 (2.1-2.4): compliance modules - `AbstractComplianceModule`, `MaxHoldersModule`, `CountryRestrictionModule`, `LockupModule` |
| 2026-07-16 | Phase 1: `IdentityRegistry` - agent path + EIP-712 attestation path, per-investor nonce, packed record |
| 2026-07-16 | Phase 0: interfaces, `Roles.sol`, sample terms document, README with scoping and access-control threat model |

---

## 📚 References

- [Guide 1: Fundamentals](./01-fundamentals.md)
- [Guide 2: Mathematics & Cryptography](./02-mathematics.md)
- [Guide 3: Architecture](./03-architecture.md)
- [Guide 4: Trade-offs](./04-tradeoffs.md)
- [Guide 5: Implementation](./05-implementation.md)
- [Guide 6: Improvements](./06-improvements.md)
- [Project README](../README.md)
- [Anchored terms document](./RealEstateNote-Terms.md)
