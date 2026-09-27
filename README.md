# EVM RWA Security Token

A proof-of-concept for compliant tokenization of a real-world financial asset (a real-estate-backed note) as a permissioned security token, modeling the identity, compliance, and custody architecture used by regulated digital-asset platforms.

> **Proof of concept. Not audited and not deployed.** This code is educational and is not fit for production or for representing real financial instruments. See [Standards and scoping](#standards-and-scoping) for what was deliberately left out.

## Implementation status

- [x] Interfaces and shared role constants
- [x] Sample terms document (`docs/RealEstateNote-Terms.md`)
- [x] `IdentityRegistry` (agent path, EIP-712 attestation path, packed record)
- [x] Compliance modules (`MaxHoldersModule`, `CountryRestrictionModule`, `LockupModule`)
- [x] `ModularCompliance` engine (composes modules, fans lifecycle hooks, superset-gate seam)
- [x] `DocumentRegistry`
- [x] `SecurityToken` (transfer gate, freeze, forced recovery)
- [x] Deployment script with document anchoring
- [x] Scenario tests
- [x] Handler-based invariant suite
- [x] Coverage report
- [x] Architecture diagram
- [x] Threat model: compliance bypass, reentrancy, recovery abuse, access control
- [x] `DividendDistributor` (accumulator pattern, O(1) income distribution, as a compliance module)

## Project progress

Built one contract per unit in dependency order, each with its own unit and fuzz tests, reviewed and committed before the next. The identity and compliance layers exist before the token because the token's transfer gate calls into both. Full detail and live status are in the [ROADMAP](docs/ROADMAP.md).

| Phase | Name | Status |
|---|---|:---:|
| 0 | Foundations (interfaces, roles, terms doc) | Done |
| 1 | Identity layer (`IdentityRegistry`) | Done |
| 2 | Compliance layer (engine + three modules) | Done |
| 3 | Document anchoring (`DocumentRegistry`) | Done |
| 4 | The security token (transfer gate, freeze, recovery) | Done |
| 5 | Deployment and hash anchoring | Done |
| 6 | Scenario and invariant testing | Done |
| 7 | Documentation and threat model | Done |
| 8 | Stretch: dividend distribution | Done |

Current state: **365 tests passing across thirteen suites** (`forge test`). `forge coverage --report summary` (no `--ir-minimum` needed) reports 100% of lines, statements, branches and functions for `SecurityToken`, `IdentityRegistry`, `ModularCompliance`, `DocumentRegistry` and `AbstractComplianceModule`, and 100% of branches and functions for the four modules, whose line figures sit between 95.83% and 98.41%: in each, the one unmarked line is the constant `return` of a `pure` view (`isPlugAndPlay` or `token`) that the tests call and check. `script/Deploy.s.sol` reports 100% of lines and functions and 51.72% of branches (15 of 29), the untaken branches being the failure sides of its `require` sanity checks. The [testing section](docs/tests/README.md) catalogues the suite as it stood before the review rounds and is rewritten in the next one.

## Documentation

The README is the narrative entry point. The technical guides in [`docs/`](docs/README.md) go deeper without repeating it:

| Guide | Covers |
|---|---|
| [Documentation index](docs/README.md) | Reading orders by audience, structure, external references |
| [1. Fundamentals](docs/01-fundamentals.md) | The asset, the permission-by-default inversion, the four moving parts, the glossary |
| [2. Mathematics & Cryptography](docs/02-mathematics.md) | The EIP-712 digest, replay closure, storage packing, holder-count and lockup arithmetic |
| [3. Architecture](docs/03-architecture.md) | Component wiring, the superset transfer gate, hook fan-out, deployment binding graph |
| [4. Trade-offs](docs/04-tradeoffs.md) | Every scope and design decision as a decision-and-alternative register |
| [5. Implementation](docs/05-implementation.md) | Conventions, OZ primitives, patterns, testing strategy, invariants |
| [6. Improvements](docs/06-improvements.md) | What a production build adds back, and the priority order |
| [7. Testing](docs/tests/README.md) | Every test catalogued and linked to its code, the invariant coverage map, and the gaps |
| [7.13 Dividends](docs/tests/13-dividend-distributor.md) | The accumulator identity, the rounding rule that keeps it solvent, and the two bugs the suite found |
| [ROADMAP](docs/ROADMAP.md) | Phased build plan and progress tracker |

## The asset

A **Series A real-estate-backed note**: a debt instrument secured by a residential property in Valencia, Spain, held through an SPV, issued by a fictional entity to a whitelist of accredited investors (the registry stores an `accredited` flag, but no module reads it, so the token does not enforce accreditation). Face value 1,000 EURC per token, 36 month maturity. The governing terms live in [`docs/RealEstateNote-Terms.md`](docs/RealEstateNote-Terms.md) and are anchored on-chain by content hash.

The asset choice matters for the architecture. A note is a claim on a real property against a real issuer, enforceable in a real court. The register of who owns that claim has to be legally defensible, which is what drives every design decision below: transfers are restricted because securities law restricts them, balances can be frozen because courts order freezes, and lost wallets can be recovered because losing a private key does not extinguish legal ownership.

## Why a permissioned token is not an ERC-20

A plain ERC-20 answers one question: does the sender have the balance? A security token has to answer a different one: **is this specific transfer, between these two specific parties, legal right now?**

That inverts the default. In an ERC-20, transfers are permitted unless the balance is insufficient. Here, transfers are forbidden unless identity and compliance both approve. Concretely:

| | ERC-20 | Permissioned security token |
|---|---|---|
| Who may hold | Anyone with an address | Only KYC-verified investors, and only while their attestation is current |
| Transfer check | Balance sufficiency | Balance, sender and recipient identity, freeze state, pause, plus a composable rule set |
| Issuer powers | None after deploy | Mint, burn, freeze (full and partial), pause, forced recovery |
| Lost keys | Funds are gone | Custodian moves the position to a new verified wallet; ownership survives the key |
| Rules change | Redeploy the token | Add or remove a compliance module; the token is untouched (with limits for stateful modules, see [Architecture](#architecture)) |

The ERC-20 interface is preserved so that existing tooling can read balances and construct transfers. The semantics underneath are different, and a wallet that assumes ERC-20 semantics will see reverts it does not expect. That is intentional: the revert is the compliance boundary doing its job.

## Standards and scoping

This project implements a **coherent subset, written from scratch**, of two standard families:

- **[ERC-3643](https://eips.ethereum.org/EIPS/eip-3643) (T-REX)** for the identity and compliance model: the identity registry, the modular compliance engine, and the gated transfer.
- **[ERC-1643](https://github.com/ethereum/EIPs/issues/1643)** (from the [ERC-1400](https://github.com/ethereum/EIPs/issues/1411) family) for document anchoring. Neither reached Final status, so the concept is borrowed rather than the specification implemented.

**This is an educational reimplementation.** A production deployment would build on the audited [`@tokenysolutions/T-REX`](https://github.com/TokenySolutions/T-REX) reference implementation rather than rewriting the standard. Everything here is written from OpenZeppelin primitives (ERC20, AccessControl, Pausable, ReentrancyGuard, EnumerableSet, ECDSA, EIP712, SafeERC20, SafeCast) on purpose: the goal is to demonstrate understanding of the architecture, not to deploy existing code.

### What was deliberately left out, and why

| Scoping decision | Rationale |
|---|---|
| **ONCHAINID collapsed into a flat registry.** ERC-3643 gives each investor an on-chain identity contract holding signed claims, resolved through `IdentityRegistryStorage`, `TrustedIssuersRegistry` and `ClaimTopicsRegistry`. Here one registry stores the attested attributes directly. | The four-contract hierarchy exists to let one identity be reused across many tokens and issuers. With a single token and a single issuer, it is ceremony without benefit. The trust model it encodes is preserved through the signed attestation path (below), which is the part that actually matters. |
| **`TrustedIssuersRegistry` reduced to a single claim signer.** | The registry answers "which issuers may attest which claim topics". With one KYC provider and one claim topic, that collapses to one address. The cryptographic verification, which is the substance, is kept. |
| **No claim topics or claim schemes.** Attributes (`country`, `accredited`, `kycExpiry`) are typed struct fields, not generic claim blobs. | Generic claims buy extensibility this POC has no use for, at the cost of making every rule parse bytes. Typed fields keep the record in one storage slot and the rules readable. |
| **ERC-1400 partitions omitted entirely.** No tranches, no partial fungibility. | Partitions model tokens with heterogeneous rights (different vesting, different classes). A single-series note has none. Only the document anchoring (ERC-1643) is borrowed. This exclusion has a downstream consequence on the lockup rule, described below: it is the clearest example in this project of a scope decision determining a security property. |
| **No upgradeability, no proxies, no factory.** | A real deployment needs all three. They are orthogonal to the identity and compliance architecture being demonstrated, and would add a proxy layer to read through with no insight gained. |

### ERC-3643: implemented and not implemented

Compared against the interfaces in the [EIP text](https://eips.ethereum.org/EIPS/eip-3643) and the T-REX reference (`IToken`, `IIdentityRegistry`, `IModularCompliance`, `IModule`). The table above says why each part was left out; this one says which functions exist.

| Area | Implemented as in the standard | Implemented differently | Not implemented |
|---|---|---|---|
| Token | `pause`, `unpause`, `setAddressFrozen`, `freezePartialTokens`, `unfreezePartialTokens`, `isFrozen`, `paused`, `identityRegistry()`, `compliance()` (both return an address) | `transfer` / `transferFrom` also require the **sender** to be verified (the standard checks only the recipient). `mint` runs the modular rules and the freeze check (the standard lets `mint` bypass compliance). `mint` and `burn` are gated by `DEFAULT_ADMIN_ROLE`, not by an agent. `getFrozenTokens` is `frozenTokens`. `recoveryAddress(lost, new, onchainID)` is `forcedRecovery(lost, new)`: no ONCHAINID argument, the two wallets must share an `investorId`, it is gated by `CUSTODIAN_ROLE`, and it skips the pause and every compliance rule. A token-level `canTransfer` view is added | `forcedTransfer`, all seven `batch*` functions, `setIdentityRegistry`, `setCompliance` (both are fixed in the constructor), `onchainID`, `setOnchainID`, `version`, `setName`, `setSymbol` |
| Agent role | | OpenZeppelin `AccessControl` with `AGENT_ROLE`, `CUSTODIAN_ROLE` and `DEFAULT_ADMIN_ROLE` instead of `IAgentRole` (`addAgent`, `removeAgent`, `isAgent`) | |
| Identity registry | | `registerIdentity(user, country, accredited, kycExpiry[, investorId])` stores attributes instead of linking an `IIdentity` contract. `deleteIdentity` is `removeIdentity`. `isVerified` checks a stored flag and `kycExpiry`, not claims. `identity` returns the stored record. `investorCountry` is `country`. Re-registering overwrites a record, which stands in for `updateCountry` and `updateIdentity`. `registerIdentityWithAttestation` (EIP-712, one claim signer) is added | `batchRegisterIdentity`, `contains`, `identityStorage`, `issuersRegistry`, `topicsRegistry` and their setters |
| Registry split | | `TrustedIssuersRegistry` is reduced to one `claimSigner` | `IdentityRegistryStorage`, `ClaimTopicsRegistry`, ONCHAINID |
| Compliance | `addModule`, `removeModule`, `canTransfer`, `transferred`, `created`, `destroyed` | `bindToken` is one-shot and cannot be rebound. `getModules`, `getTokenBound` and `isModuleBound` are `modules`, `token` and `isModuleRegistered`. `addModule` also checks that the module names this engine, that `canComplianceBind` allows it, and that the module reads the bound token (`bindToken` checks the same for modules registered earlier) | `unbindToken`, `isTokenBound`, `callModuleFunction` |
| Module | `name`, `isPlugAndPlay`, `canComplianceBind`, `isComplianceBound`, `bindCompliance`, `unbindCompliance` (called by the engine from `addModule` and `removeModule`) | `moduleTransferAction`, `moduleMintAction` and `moduleBurnAction` are `moduleTransferred`, `moduleCreated` and `moduleDestroyed`. `moduleCheck` takes no compliance argument. A module serves one engine, fixed in its constructor, rather than a list of bound compliances. A `token()` view is added | |

The last row follows T-REX for the reason T-REX has it. A stateful module such as T-REX's `MaxBalanceModule` reports `isPlugAndPlay() == false`, and its `canComplianceBind` refuses a compliance whose token already has supply. Here `MaxHoldersModule` and `LockupModule` refuse a token with supply, and every stateful module refuses to be attached a second time (see [Architecture](#architecture)). T-REX also gates `recoveryAddress` to an agent, where this repository uses a separate `CUSTODIAN_ROLE`.

### The two registration paths

The identity registry accepts records through two doors, which exist to make an argument about trust:

1. **`registerIdentity`** (AGENT only). The compliance officer writes the record directly, transcribing an off-chain KYC result. Trust rests entirely on the agent: a compromised agent key writes whatever it likes.

2. **`registerIdentityWithAttestation`** (permissionless to submit). The caller supplies an EIP-712 attestation signed by the authorized claim signer. The registry recovers the signer and rejects anything it did not sign. Trust rests on the signature, not on whoever pays for the transaction.

The second path is ERC-3643's trust model in miniature, and it is the reason the standard bothers with ONCHAINID at all: **verification should not rest on trusting whoever writes to the registry.** The signed payload binds the investor, the attributes, the expiry, the investor id, and a per-investor nonce, under a domain separator carrying the chain ID and the registry address.

Each of those bindings closes a specific hole. The domain separator stops a signature from being replayed on another chain or against another registry deployment. The expiry stops it from being replayed after the KYC lapses. The nonce closes the gap the expiry leaves open: without it, an attestation replayed *within* its validity window could silently re-register an investor the agent had just removed. That last one is the subtle one, and it is why the nonce is not optional. Every write to a record advances it (a signed registration, an agent registration and a removal), so an attestation that was issued but never submitted also dies with the next write.

### Why the lockup runs from initial acquisition, not from each acquisition

This is worth spelling out because it is a case where excluding a feature forced a different rule, and the two cannot be reasoned about separately.

The anchored terms document specifies a 12-month lockup. The obvious reading is per-acquisition: every time you receive tokens, those tokens are locked for a year. Implemented literally on a fungible balance, that means **every incoming transfer restarts the clock on the entire position**, and that is a vulnerability, not a rule:

> Anyone can send a victim 1 wei of the token and re-lock their whole position for another year. It costs the attacker one dust transfer and can be repeated forever. A lockup a hostile third party can trigger against you for free is a denial of service wearing a compliance costume.

The strict reading is only implementable if each **parcel** of tokens carries its own clock, so that receiving dust locks the dust and nothing else. Per-parcel accounting is precisely what ERC-1400 partitions (tranches) provide, and partitions are out of scope here by design. **Without tranches, the per-acquisition model cannot be implemented safely**, so the rule is:

- The clock starts on the transition from zero to a positive balance (initial acquisition), whether by mint or by transfer. Primary issuance is the archetypal acquisition, so mint starts the clock, through the same code path that observes the zero to positive transition on a transfer.
- Subsequent receipts never reset it. This single guard (`lockStart != 0`, do not overwrite) is the anti-griefing property, and it is tested explicitly, including the 1-wei re-lock attempt.
- Exiting to a zero balance clears the clock, so an investor who sells out and later buys back is locked afresh rather than keeping an expired clock forever.

The anchored terms document says "from initial acquisition" so that the legal document and the contract describe the same instrument: a mismatch between the anchored terms and the enforced behavior would undermine the point of anchoring them at all.

## On-chain and off-chain boundary

The contracts are not the system. They are the enforcement surface of a system that mostly lives elsewhere, and being precise about that line is most of the architecture.

| Lives off-chain | Crosses the boundary as | Enforced on-chain as |
|---|---|---|
| KYC/AML identity verification, sanctions screening, accreditation checks (a licensed provider, holding documents that must never be public) | An attestation: signed EIP-712 payload, or an agent transaction | An `Identity` record with `country`, `accredited`, `kycExpiry` |
| The property, the SPV, the note indenture, the valuation | Nothing directly. The token represents the claim; it does not contain it | Total supply, backed by an off-chain legal instrument |
| Legal documents (prospectus, terms) | `keccak256` of the document content, plus a URI | A `DocumentRegistry` anchor |
| Custody operations, key ceremonies, the decision that a wallet is lost | A custodian transaction | `forcedRecovery`, gated by `CUSTODIAN_ROLE` |
| The regulator's rule set (who may hold, which jurisdictions, holding periods) | A governance decision to plug in a module | A `ComplianceModule` registered on the engine |

Two properties of this boundary are worth stating plainly.

**On-chain data is a projection, not a source of truth.** `isVerified` returning true does not mean an investor passed KYC. It means someone attested that they did, and the attestation has not expired. The chain records the claim and its provenance; it cannot validate the underlying fact. This is why `kycExpiry` exists: an attestation is a statement with a shelf life, and a permanent `verified` flag would quietly become a lie.

**The document hash is of the content, not the URI.** The URI says where the terms live and can be re-hosted freely. The hash proves which exact bytes are in force. A holder fetches the document, hashes it, and compares. If the issuer silently amends the terms, the hash stops matching and the substitution is evident on-chain. Hashing the URI instead would prove only that a link did not change, which is worth nothing.

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

## Architecture

Eight contracts: the seven that `Deploy.s.sol` deploys, plus the optional `DividendDistributor`. An investor mostly touches the token, which consults the rest on their behalf; the exceptions are `claim` on the distributor and the permissionless `registerIdentityWithAttestation` on the registry.

```
     ISSUER            AGENT                CUSTODIAN
   (mint, burn,   (freeze, pause,          (forcedRecovery)
    config)        onboard, rules)
        │                │                       │
        └────────────────┴───────────┬───────────┘
                                     ▼
                        ┌──────────────────────────┐
        holder ────────►│      SecurityToken       │
       transfer()       │  ERC20 · AccessControl   │
                        │  Pausable · ReentrancyG. │
                        └───┬──────────────────┬───┘
                            │                  │
             isVerified()   │                  │  canTransfer()  (before)
             investorId()   │                  │  transferred()  (after)
             removeIdentity()                  │  created() / destroyed()
                            ▼                  ▼
              ┌──────────────────┐   ┌──────────────────────┐
              │ IdentityRegistry │   │  ModularCompliance   │
              │  AccessControl   │   │  EnumerableSet of    │
              │  + EIP712        │   │  modules, bound once │
              └──────────────────┘   └──┬────────┬───────┬───────┬──┘
                                        ▼        ▼       ▼       │
                                 ┌──────────┐ ┌───────┐ ┌────────┐│
                                 │MaxHolders│ │Country│ │ Lockup ││
                                 │  Module  │ │Restr. │ │ Module ││
                                 └──────────┘ └───────┘ └────────┘│
                                    rules: they can veto a transfer│
                                                                   ▼
                                                    ┌──────────────────────┐
                                       ISSUER ─────►│  DividendDistributor │
                                       deposit()    │  observer: never     │
                                       holder ─────►│  vetoes, only counts │
                                        claim()     └──────────────────────┘

              ┌──────────────────┐
   ISSUER ───►│ DocumentRegistry │   standalone: anchors the terms by
              └──────────────────┘   content hash, nothing reads it on-chain
```

Two structural invariants define the shape:

1. **The token references the engine, never a module.** Changing the rule set is a governance action on the engine (`addModule` / `removeModule`), not a token redeploy.
2. **Each binding is set once and is not rebindable.** A module names its engine as an `immutable`; the engine's `bindToken` reverts if a token is already bound. This is what stops a second caller from driving the lifecycle hooks of a stateful module and desynchronizing its state from real balances.

`DocumentRegistry` deliberately hangs off to the side: no contract reads it. Anchoring is a claim made to holders and auditors, not an input to the transfer decision.

**`DividendDistributor` is a module, but not a rule.** The module interface has two halves: `moduleCheck`, which decides whether a transfer is allowed, and the lifecycle hooks, which observe that one settled. The three rule modules use both. The distributor implements `moduleCheck` as an unconditional `true` and puts all of its logic in the hooks, using the fan-out as an on-chain event bus and giving up the power of veto. Withholding income from a sanctioned holder is a matter for the token's freeze and identity controls, not the transfer gate: `claim` reverts while the holder is fully frozen or not verified (an expired KYC counts), the entitlement keeps accruing, and it becomes claimable once the block is lifted. A partial freeze does not block a claim, since it immobilises tokens, not the holder.

That choice is why income distribution required no change to `SecurityToken` beyond a single view, and why it can be registered on a live deployment with `addModule`. It also has a limit worth stating: `moduleTransferred(from, to, amount)` is byte-identical for a sale and for a forced recovery, and those mean opposite things for anything that accrues value to a holder. The distributor therefore has to ask the token which it is (`recovering()`), making it one of the two modules that depend on the token being a `SecurityToken` rather than any ERC-20 (`LockupModule` asks the same question, see below), and it reads the token's freeze state and identity registry in `claim`. A system with several value-accruing modules would want the transfer kind passed through the hook itself.

**The engine refuses to attach a stateful module it cannot keep in step.** A module only sees the movements that happen while it is registered, and nothing reconciles its state with existing balances, so the engine asks the module first (`canComplianceBind`, the T-REX shape) and reverts with `ModuleCannotBind` when it says no:

- `MaxHoldersModule` and `LockupModule` refuse while the token has supply. A holder count added late would start at zero and make the first existing holder's exit underflow; a lockup added late would have no clock for existing holders.
- Every stateful module (those two and `DividendDistributor`) refuses a second attach after a removal, because it missed every movement made while it was out.
- `DividendDistributor` may join a live token once: its accumulator starts at zero, so balances that predate it simply earn from the first deposit it sees. After a removal it rejects `deposit` (`DistributorNotAttached`) and keeps paying what accrued while it was attached.
- `CountryRestrictionModule` is stateless (`isPlugAndPlay`) and can be removed and attached again at any time.
- A module that reads balances must read the engine's own token: `addModule` and `bindToken` both reject a mismatch (`ModuleTokenMismatch`).

Rules can change without redeploying the token; a stateful rule has to be in place before the balances it tracks. Adding one to an issued token means deploying the token again with it.

### The transfer gate

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

`_checkTransfer` is one internal function returning a status code, ordered so the common rejections short-circuit before the module iteration, which is the expensive step:

```
1. recipient verified?              registry call
2. recipient not frozen?            token SLOAD
3. sender verified?                 registry call    ┐
4. sender not frozen?               token SLOAD      ├ skipped on mint
5. unfrozen balance >= amount?      token SLOAD      ┘
6. ModularCompliance.canTransfer    external call, iterates every module  ← last
```

Both the public `canTransfer` view and the reverting `_update` path call this same function: the view compares the code to `Ok`, `_update` translates it into the matching custom error. For ordinary transfers and mints they cannot drift, because a front end's pre-check and the on-chain enforcement are the same code. Burn and forced recovery do not pass through the gate, so `canTransfer` is not a pre-check for those two shapes.

The two non-obvious branches:

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

Steps 5-9 are why recovery relocates a position without laundering a hold: a frozen lot arrives frozen at its new address, and the event log shows both halves. During step 8 the lifecycle hook fires, and the two modules that hold per-wallet state ask the token whether a recovery is in progress: `LockupModule` moves the lockup start instead of starting a fresh clock (the destination keeps the earlier of the two starts), and `DividendDistributor` moves the unclaimed income. Step 3 works on a wallet the agent already removed, because removal keeps the `investorId`. Step 3 is what keeps a compromised custodian key from recovering into an arbitrary verified wallet; see [Threat model](#threat-model) for how far that constraint actually goes.

### Deployment order

The bindings impose a strict construction order; each arrow is a dependency that must already exist.

```
  1. ModularCompliance(issuer)          engine first: modules take its address as immutable
  2. IdentityRegistry(issuer, agent)
  3. SecurityToken(issuer, registry, engine)     both are constructor args, no setters
  4. MaxHolders(engine, token, ...)       ┐ MaxHolders and Lockup read balances,
     Lockup(engine, token, ...)           │ so they need the token address;
     CountryRestriction(engine, registry) ┘ Country reads the investor's country
  5. wiring:  engine.addModule(each)      also asserts step 4 bound the right engine
              engine.bindToken(token)     one-shot
              registry.grantRole(AGENT_ROLE, token)   ← for removeIdentity in recovery
              token.grantRole(AGENT_ROLE, agent)
              token.grantRole(CUSTODIAN_ROLE, custodian)
  6. DocumentRegistry(issuer) + setDocument(TERMS, uri, hash)
```

Note that this is *not* the order a naive reading suggests (engine, modules, registry, token): `MaxHolders` and `Lockup` hold the token as an `immutable`, so they cannot precede it, and the token takes the engine in its constructor with no setter. `Deploy.s.sol` performs this, hashes `docs/RealEstateNote-Terms.md` as read at deployment, and reverts with `TermsHashMismatch` unless that hash equals the pinned `TERMS_HASH`. `DeployTest` pins the same value independently, and `test_deploy_revertsWhenTermsDrift` shows a drifted document failing the deployment. Amending the terms before a deployment therefore means changing the file and both constants on purpose; after deployment, it goes through `setDocument` on the registry.

The script deploys and wires the three rule modules only. `DividendDistributor` is not part of it (`_verify` requires exactly three modules); the dividend scenario suite deploys and registers it separately.

One limitation the script does not hide: the wiring calls are admin-gated, so the executing account must be the issuer. When the `ISSUER`, `AGENT` and `CUSTODIAN` environment variables are unset, all three roles go to the broadcasting account, which suits a local Anvil run and nothing else; `test_run_wiresTheSystemWithDefaultAndExplicitRoles` runs `run()` end to end both ways. A real deployment needs a deploy-then-handover step (deploy under a hot key, transfer `DEFAULT_ADMIN_ROLE` to the multisig, renounce), which is governance plumbing deliberately out of scope here.

Deeper treatment of each seam is in [Guide 3: Architecture](docs/03-architecture.md).

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
| Deflate the holder count to walk past the cap | Every stateful hook ignores a zero amount. **This was a real bug**, found in review: a zero-amount send from a verified wallet holding nothing read as "the sender left", and `transferFrom(emptyWallet, x, 0)` needs no allowance, so any address could drain the count, admit holders past the cap, and then make legitimate exits underflow (see [Review notes](#review-notes)) |
| Attach a holder cap or a lockup to a token that already has holders | `addModule` reverts (`ModuleCannotBind`): those modules refuse a token with supply, and every stateful module refuses a second attach |

The last rows are the honest part of this section. The holder-count and lockup modules both infer transitions from post-transfer balances rather than reading pre-transfer state, and that inference is where the bugs live. `invariant_holderCountMatchesReality` cross-checks the incremental count against enumerated real balances on every run, and its handler now issues zero amounts, full-balance moves and `transferFrom`; reintroducing the zero-amount bug makes it fail.

What is *not* defended: a rule the module set does not encode is not enforced. The gate is exactly as strict as the registered modules, and the ISSUER can remove them.

The gate also checks the two holders, not the caller. In `transferFrom` the spender needs only an allowance, so an unverified or frozen spender can move tokens between two verified, unfrozen holders; ERC-3643 behaves the same way. Allowances a lost wallet granted survive `forcedRecovery` and are not carried to the new wallet. They cannot move anything while the lost wallet holds nothing and stays unregistered.

### 2. Reentrancy (defended, mostly structurally)

The token makes external calls to the registry and to the engine, and the engine calls out to every module, so the surface exists on the transfer path even though no ether and no arbitrary callee is involved there.

The ordering in `_update` is CEI: checks, then `super._update` settles balances, then the engine hook fires. A module reentering the token during that hook therefore observes **already-settled** balances and gets no inconsistent intermediate state to exploit; it would simply face the gate again as a fresh transfer.

`forcedRecovery` carries `nonReentrant` on top of that, for a specific reason: it is the one function that mutates freeze state *around* a transfer (snapshot, clear, move, re-apply). A reentrant call landing between the clear and the re-apply is the one window where the freeze could be dropped, and the guard closes it. `_recovering` is set and cleared within that same guarded call, so the gate exemption cannot leak into any other transaction.

The residual assumption: **modules are trusted code the issuer registers**, not arbitrary third-party contracts. A malicious module can revert every transfer (a denial of service the issuer can undo by removing it) and can consume unbounded gas in the hook fan-out, which iterates all modules without a cap. Vetting what gets registered is a governance responsibility, not a property the engine enforces.

`DividendDistributor` is the first contract here that moves value *out* to an arbitrary address, which makes it the first place where reentrancy is a live concern rather than a structural one. `claim` records the withdrawal before transferring (CEI) and carries `nonReentrant` on top, because the settlement currency is external code: a token with a transfer callback, or an outright malicious one, gets control after the payout is recorded. Both `deposit` and `claim` are guarded. The [test suite](docs/tests/13-dividend-distributor.md#claiming) drives an attack with a currency that reenters `claim` from inside its own `transfer` and one that reenters `deposit` from inside `transferFrom`; each records that it attempted the reentry and the test asserts the guard's error. For `claim` the guard is the first line rather than the only one: the withdrawal is recorded before the payout, so a reentrant claim would also find nothing left. `test_forcedRecovery_isReentrancyGuarded` does the same for recovery, with a registered module holding `CUSTODIAN_ROLE` that reenters from the recovery's own hook. The distributor also never pushes: it pays only the caller's own entitlement, so one holder who cannot receive the currency cannot block anyone else.

### 3. Recovery abuse (constrained and auditable, not prevented)

`forcedRecovery` moves an investor's entire balance on a custodian's say-so, exempt from the pause and from every compliance rule. That is the largest single power in the system, so what constrains it matters.

- **Destination must be verified** and **must carry the same `investorId` as the lost wallet**. Without the second check, a custodian could recover into any verified address, including one they control as an onboarded investor, and, via the freeze carry-over, freeze whatever that address already held.
- **The freeze state travels with the position.** A partial freeze is additive at the destination; a full freeze applies to the whole destination wallet, which is intentional, since the `investorId` check already requires it to belong to the same investor. Recovery relocates a hold, it does not launder one.
- **The lost wallet is evicted** from the registry in the same call, so it can no longer send or receive. The eviction is not permanent: an agent can register the wallet again, after which it can hold the token. Removal clears the verification but keeps the `investorId`, so a wallet the agent had already suspended can still be recovered.
- **The lockup travels with the position.** Recovery does not restart the holding period: the destination takes the lost wallet's lockup start, or keeps its own if that is earlier.
- **Supply is unchanged** and every recovery emits `RecoverySuccess` naming both wallets and the carried freeze state.
- **Unclaimed income travels with the position.** This did not come for free. Settled as an ordinary transfer, the accumulator leaves accrued dividends on the lost wallet, so the tokens are rescued while the money stays claimable by whoever holds the compromised keys. The distributor branches on `recovering()` and carries the entitlement across; the behaviour is [tested end to end](docs/tests/13-dividend-distributor.md#forced-recovery) against the real recovery path, not only against a mock.

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

## Review notes

The code was reviewed in rounds after the build. Each finding below was reproduced first, got a regression test that failed against the unfixed code, and was then fixed. The regression tests that run against the deployed wiring live in [`test/scenario/Regressions.t.sol`](test/scenario/Regressions.t.sol).

**1. Zero amounts deflated the holder count** (`22e214f`)
- Wrong: a zero-amount transfer from a verified wallet holding nothing lowered `MaxHoldersModule.holderCount`. `transferFrom(emptyWallet, x, 0)` needs no allowance, so any address could drain the count, admit holders past the cap, and then make legitimate exits revert on underflow. `burn(nonHolder, 0)` did the same.
- Root cause: the hook infers "the sender left" from `balanceOf(from) == 0` after the move, which is also true for a sender that held nothing before.
- Fix: every stateful hook returns early on a zero amount. Zero-amount transfers stay valid ERC-20 calls.
- Tests: `test_zeroAmountTransfer_doesNotDeflateHolderCount`, `test_zeroAmountTransferFromByStranger_doesNotDeflateHolderCount`, `test_zeroBurnFromNonHolder_doesNotDeflateHolderCount`, `test_zeroAmountSends_doNotBlockLaterExits`.

**2. An unsubmitted attestation could undo a removal** (`480b897`)
- Wrong: an attestation issued while an investor was registered, but never submitted, re-registered them after the agent removed them.
- Root cause: only a signed registration advanced the nonce; agent registrations and removals did not.
- Fix: every write to a record advances the nonce.
- Tests: `test_attestationSignedBeforeRemoval_isRejectedAfterIt`, `test_attestationSignedBeforeAgentUpdate_isRejectedAfterIt`.

**3. A suspended wallet could not be recovered** (`4975329`)
- Wrong: after the agent removed a wallet's identity, `forcedRecovery` reverted with `RecoveryAcrossInvestors(0, id)`, so the position stayed stranded until the agent registered the lost wallet again.
- Root cause: `removeIdentity` deleted the whole record, `investorId` included.
- Fix: removal clears the verification and attributes but keeps `investorId`; recovery skips its own removal call when the wallet is already removed.
- Test: `test_forcedRecovery_succeedsAfterAgentRemovedLostWallet`.

**4. Forced recovery restarted the lockup** (`498c4ef`)
- Wrong: recovering a position into an empty wallet locked the investor again for the full period.
- Root cause: the recovery hook is the ordinary transfer hook, which `LockupModule` read as a fresh acquisition.
- Fix: `LockupModule` asks the token `recovering()` and moves the start instead: an empty destination takes the lost wallet's start, a holding destination keeps the earlier of the two.
- Tests: `test_forcedRecovery_keepsAnExpiredLockupExpired`, `test_forcedRecovery_keepsTheOriginalUnlockTime`, `test_forcedRecovery_intoHoldingWallet_keepsTheEarlierStart`.

**5. Frozen and unverified holders could claim income** (`2c8ea7c`)
- Wrong: `DividendDistributor.claim` paid a holder who was fully frozen or no longer verified.
- Root cause: `claim` read neither the token's freeze state nor the identity registry.
- Fix: `claim` reverts with `ClaimantFrozen` or `ClaimantNotVerified` (an expired KYC counts). The entitlement keeps accruing and is released when the block is lifted. A partial freeze does not block a claim.
- Tests: `test_claim_blockedWhileFullyFrozen_releasedAfterUnfreeze`, `test_claim_blockedWhileUnverified_releasedAfterReverification`, `test_claim_blockedAfterKycExpiry`, `test_claim_allowedUnderPartialFreeze`.

**6. Stateful modules could be attached where they could not keep up** (`f9ab7b1`, `a957a53`)
- Wrong: a holder cap added to a token with holders started at zero and made the first exit underflow; a late lockup had no clock for existing holders; a distributor removed and added back overpaid holders who bought while it was out.
- Root cause: `addModule` and `removeModule` reconciled nothing with existing balances.
- Fix: the T-REX `isPlugAndPlay` / `canComplianceBind` shape. The holder cap and the lockup refuse a token with supply, every stateful module refuses a second attach, and a detached distributor refuses deposits. The follow-up commit makes the attachment events name the bound engine rather than a caller-supplied address.
- Tests: `test_addModule_rejectsMaxHoldersOnceSupplyExists`, `test_addModule_rejectsLockupOnceSupplyExists`, `test_addModule_rejectsReattachingARemovedStatefulModule`, `test_addModule_rejectsReattachingARemovedDistributor`, `test_distributor_afterRemoval_refusesDepositsAndPaysAccrued`.

**7. A module could read a different token than the engine's** (`3bdb0c8`)
- Wrong: a stateful module built against another token was accepted and then counted that token's balances.
- Root cause: `addModule` checked only that the module named this engine.
- Fix: `addModule` and `bindToken` reject a module whose `token()` differs from the bound token.
- Tests: `test_addModule_rejectsModuleBuiltForAnotherToken`, `test_bindToken_rejectsRegisteredModuleForAnotherToken`.

**8. An over-burn panicked** (`aa6a0fd`)
- Wrong: burning more than the balance of a wallet with frozen tokens reverted with an arithmetic panic.
- Root cause: the frozen-portion arithmetic ran before the ERC-20 balance check.
- Fix: `burn` checks the balance first and reverts with `ERC20InsufficientBalance`.
- Test: `test_burn_aboveBalance_revertsWithInsufficientBalance`.

**9. Recovery left no unfreeze trail** (`e200018`)
- Wrong: recovery cleared the lost wallet's freeze without an event, so freeze state rebuilt from events kept the retired wallet frozen.
- Fix: recovery emits `TokensUnfrozen` and `AddressFrozen(false)` for what it clears, before the move.
- Test: `test_forcedRecovery_emitsTheFullFreezeEventSequence`.

**10. `isVerified` read two slots** (`3b1ca76`)
- Wrong: the identity check, run twice per transfer, also loaded the investor id slot.
- Root cause: the record was copied to memory.
- Fix: the two fields are read through a storage pointer; the token's registry and engine references became `immutable`.
- Test: `test_isVerified_readsOneStorageSlot`.

**11. An edited terms document was anchored instead of rejected** (`b582a2a`)
- Wrong: the deployment hashed whatever the terms file contained and compared the anchor with the same file.
- Fix: `Deploy.s.sol` and `DeployTest` both pin the hash, and a drifted file fails the deployment.
- Test: `test_deploy_revertsWhenTermsDrift`.

Test-suite changes from the same review (handler revert classification, new invariants, stronger unit tests) are in the commits after `55b7fbd`; the [testing section](docs/tests/README.md) will be rewritten to match in the next round.

## Build and test

Requires [Foundry](https://book.getfoundry.sh/getting-started/installation).

```bash
git clone --recurse-submodules https://github.com/GushALKDev/evm-rwa-security-token
cd evm-rwa-security-token
forge build
forge test
```

Formatting is `forge fmt` with the default configuration (`foundry.toml` has no `[fmt]` section). CI ([`.github/workflows/test.yml`](.github/workflows/test.yml)) runs `forge fmt --check`, `forge build --sizes` and `forge test -vvv` under `FOUNDRY_PROFILE=ci` on every push and pull request.

`forge test` runs all 365 tests across thirteen suites (nine unit, three scenario, one invariant): 291 unit tests and 22 fuzz tests in the unit suites, 39 scenario tests (including the 25 in `Regressions.t.sol`), and 12 stateful invariants plus one deterministic reachability test in the invariant suite. Gas benchmarks live in `test/gas/`, are excluded from that count and from the default and `ci` profiles, and run with `FOUNDRY_PROFILE=gas forge test --isolate --gas-report`. The default profile runs 256 fuzz runs per fuzz test and 64 runs of depth 64 per invariant; the `ci` profile (`FOUNDRY_PROFILE=ci forge test`) raises these to 1,000 fuzz runs and 256 invariant runs of depth 128. The invariant suite is worth running deeper than its default before trusting a change to a stateful module:

```bash
FOUNDRY_INVARIANT_RUNS=300 FOUNDRY_INVARIANT_DEPTH=100 forge test --match-path 'test/invariant/*'
```

That configuration is what surfaced the holder-count self-transfer bug.

The dividend arithmetic is sensitive to rounding in a way the default fuzz budget does not probe, so its properties are run deeper too:

```bash
FOUNDRY_FUZZ_RUNS=20000 forge test --match-contract DividendDistributorTest
```

The compounding-insolvency bug that suite found was only reachable across *repeated* deposits: every single-deposit property passed while the contract was quietly becoming insolvent. See the [testing section](docs/tests/README.md) for the full catalogue.

## License

MIT, see [LICENSE](LICENSE). Unaudited, educational, not for production use.
