# EVM RWA Security Token (In progress)

A proof-of-concept for compliant tokenization of a real-world financial asset (a real-estate-backed note) as a permissioned security token, modeling the identity, compliance, and custody architecture used by regulated digital-asset platforms.

> **Unaudited educational proof-of-concept.** This code has not been audited and is not fit for production or for representing real financial instruments. See [Standards and scoping](#standards-and-scoping) for what was deliberately left out.

## Implementation status

- [x] Interfaces and shared role constants
- [x] Sample terms document (`docs/RealEstateNote-Terms.md`)
- [ ] `IdentityRegistry` (agent path, EIP-712 attestation path, packed record)
- [ ] Compliance modules (`MaxHoldersModule`, `CountryRestrictionModule`, `LockupModule`)
- [ ] `ModularCompliance` engine
- [ ] `DocumentRegistry`
- [ ] `SecurityToken` (transfer gate, freeze, forced recovery)
- [ ] Deployment script with document anchoring
- [ ] Scenario tests
- [ ] Handler-based invariant suite
- [ ] Coverage report
- [ ] Architecture diagram
- [ ] Threat model: compliance bypass, reentrancy, recovery abuse (access control done)

## The asset

A **Series A real-estate-backed note**: a debt instrument secured by a residential property in Valencia, Spain, held through an SPV, issued by a fictional entity to a whitelist of accredited investors. Face value 1,000 EURC per token, 36 month maturity. The governing terms live in [`docs/RealEstateNote-Terms.md`](docs/RealEstateNote-Terms.md) and are anchored on-chain by content hash.

The asset choice matters for the architecture. A note is a claim on a real property against a real issuer, enforceable in a real court. The register of who owns that claim has to be legally defensible, which is what drives every design decision below: transfers are restricted because securities law restricts them, balances can be frozen because courts order freezes, and lost wallets can be recovered because losing a private key does not extinguish legal ownership.

## Why a permissioned token is not an ERC-20

A plain ERC-20 answers one question: does the sender have the balance? A security token has to answer a different one: **is this specific transfer, between these two specific parties, legal right now?**

That inverts the default. In an ERC-20, transfers are permitted unless the balance is insufficient. Here, transfers are forbidden unless identity and compliance both approve. Concretely:

| | ERC-20 | Permissioned security token |
|---|---|---|
| Who may hold | Anyone with an address | Only KYC-verified investors, and only while their attestation is current |
| Transfer check | Balance sufficiency | Balance, recipient identity, freeze state, pause, plus a composable rule set |
| Issuer powers | None after deploy | Mint, burn, freeze (full and partial), pause, forced recovery |
| Lost keys | Funds are gone | Custodian moves the position to a new verified wallet; ownership survives the key |
| Rules change | Redeploy the token | Add or remove a compliance module; the token is untouched |

The ERC-20 interface is preserved so that existing tooling can read balances and construct transfers. The semantics underneath are different, and a wallet that assumes ERC-20 semantics will see reverts it does not expect. That is intentional: the revert is the compliance boundary doing its job.

## Standards and scoping

This project implements a **coherent subset, written from scratch**, of two standard families:

- **[ERC-3643](https://eips.ethereum.org/EIPS/eip-3643) (T-REX)** for the identity and compliance model: the identity registry, the modular compliance engine, and the gated transfer.
- **[ERC-1643](https://github.com/ethereum/EIPs/issues/1643)** (from the [ERC-1400](https://github.com/ethereum/EIPs/issues/1411) family) for document anchoring. Neither reached Final status, so the concept is borrowed rather than the specification implemented.

**This is an educational reimplementation.** A production deployment would build on the audited [`@tokenysolutions/T-REX`](https://github.com/TokenySolutions/T-REX) reference implementation rather than rewriting the standard. Everything here is written from OpenZeppelin primitives (ERC20, AccessControl, Pausable, ReentrancyGuard, EnumerableSet, ECDSA) on purpose: the goal is to demonstrate understanding of the architecture, not to deploy existing code.

### What was deliberately left out, and why

| Scoping decision | Rationale |
|---|---|
| **ONCHAINID collapsed into a flat registry.** ERC-3643 gives each investor an on-chain identity contract holding signed claims, resolved through `IdentityRegistryStorage`, `TrustedIssuersRegistry` and `ClaimTopicsRegistry`. Here one registry stores the attested attributes directly. | The four-contract hierarchy exists to let one identity be reused across many tokens and issuers. With a single token and a single issuer, it is ceremony without benefit. The trust model it encodes is preserved through the signed attestation path (below), which is the part that actually matters. |
| **`TrustedIssuersRegistry` reduced to a single claim signer.** | The registry answers "which issuers may attest which claim topics". With one KYC provider and one claim topic, that collapses to one address. The cryptographic verification, which is the substance, is kept. |
| **No claim topics or claim schemes.** Attributes (`country`, `accredited`, `kycExpiry`) are typed struct fields, not generic claim blobs. | Generic claims buy extensibility this POC has no use for, at the cost of making every rule parse bytes. Typed fields keep the record in one storage slot and the rules readable. |
| **ERC-1400 partitions omitted entirely.** No tranches, no partial fungibility. | Partitions model tokens with heterogeneous rights (different vesting, different classes). A single-series note has none. Only the document anchoring (ERC-1643) is borrowed. |
| **No upgradeability, no proxies, no factory.** | A real deployment needs all three. They are orthogonal to the identity and compliance architecture being demonstrated, and would add a proxy layer to read through with no insight gained. |

### The two registration paths

The identity registry accepts records through two doors, which exist to make an argument about trust:

1. **`registerIdentity`** (AGENT only). The compliance officer writes the record directly, transcribing an off-chain KYC result. Trust rests entirely on the agent: a compromised agent key writes whatever it likes.

2. **`registerIdentityWithAttestation`** (permissionless to submit). The caller supplies an EIP-712 attestation signed by the authorized claim signer. The registry recovers the signer and rejects anything it did not sign. Trust rests on the signature, not on whoever pays for the transaction.

The second path is ERC-3643's trust model in miniature, and it is the reason the standard bothers with ONCHAINID at all: **verification should not rest on trusting whoever writes to the registry.** The signed payload binds the investor, the attributes, the expiry, and a per-investor nonce, under a domain separator carrying the chain ID and the registry address.

Each of those bindings closes a specific hole. The domain separator stops a signature from being replayed on another chain or against another registry deployment. The expiry stops it from being replayed after the KYC lapses. The nonce closes the gap the expiry leaves open: without it, an attestation replayed *within* its validity window could silently re-register an investor the agent had just removed. That last one is the subtle one, and it is why the nonce is not optional.

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
| `addModule`, `removeModule`, `bindToken` | ModularCompliance | X | | |
| `setDocument`, `removeDocument` | DocumentRegistry | X | | |
| `registerIdentityWithAttestation` | IdentityRegistry | \* | \* | \* |

\* Permissionless: anyone may submit, authorization comes from the claim signer's signature.

The split is meant to reflect how a regulated desk actually operates. **AGENT** is the compliance officer: an operational role, used daily, to onboard investors and freeze balances. **CUSTODIAN** is the recovery role, used rarely and under a legal process. They are separate so that day-to-day compliance operations carry no power to seize an investor's position. **ISSUER** controls supply and configuration but cannot freeze or recover directly.

Two edges worth flagging:

- **The `SecurityToken` contract itself holds `AGENT_ROLE` on the `IdentityRegistry`.** `forcedRecovery` must retire the lost wallet from the registry, and `removeIdentity` is agent-gated. The role is held by the contract, not by a person, and it is exercised only inside recovery.
- **ISSUER can grant itself AGENT and CUSTODIAN.** The separation above is an operational control, not a cryptographic one. See [Threat model](#threat-model) for why that is deliberate and what it does and does not protect.

## Architecture

> To be written once the transfer gate is implemented, so that the diagram reflects the code rather than the intention.

## Threat model

> Compliance-bypass paths, reentrancy, and recovery abuse will be written against the finished implementation. The access-control model is settled and documented below.

Access control here spans two threat models that are easy to conflate and should not be. One is a risk the design defends against. The other is a trust assumption the design accepts.

### 1. Operational key compromise (defended)

The keys used most often are the ones most likely to leak. `AGENT_ROLE` is exercised daily to onboard investors and manage freezes; `CUSTODIAN_ROLE` is exercised rarely but holds the power to move balances. Separating them is real defense-in-depth over the exposed surface:

- A **compromised AGENT key** can freeze balances, onboard bogus investors, and pause the token. It **cannot** perform `forcedRecovery`, so it cannot move an existing investor's position, and it cannot mint or burn.
- A **compromised CUSTODIAN key** can perform recovery. It cannot mint, burn, freeze, or write the identity registry.

Neither key alone reaches the other's powers, which is the point of the split. But the containment is asymmetric, and the honest version is worth stating: **a compromised CUSTODIAN key is the more dangerous of the two.**

`forcedRecovery` can only target a destination that is already verified, but that constraint is weaker than it looks. The attacker does not need to verify a wallet of their own: any verified wallet they already control works, and a custodian who is also an onboarded investor has one by definition. So a lone compromised custodian key can drain positions to a legitimate-looking destination. What it cannot do is hide: every recovery emits `RecoverySuccess` naming both wallets, the destination is a KYC-identified investor rather than an anonymous address, and total supply is unchanged, so the theft is legible on-chain and attributable to a real identity off-chain.

That is the actual mitigation, and it is worth being precise about its nature: recovery is **deterred and auditable, not prevented**. This is why `CUSTODIAN_ROLE` is the role a production deployment should hold to the highest key-management standard (multisig, hardware custody, an approval process tied to the legal determination that a wallet is genuinely lost) rather than the one it treats as rarely-used and therefore low-risk. Frequency of use is not the same as blast radius.

### 2. Issuer-level authority (accepted, not defended)

**ISSUER holds `DEFAULT_ADMIN_ROLE` and can grant itself `AGENT_ROLE` and `CUSTODIAN_ROLE` at will.** This is an accepted centralization assumption, not an oversight.

It is faithful to ERC-3643 and to the regulatory reality the standard encodes: the issuer is the responsible party for the instrument. They answer to the regulator, they are liable to holders, and they are the entity a court orders to act. A token that could refuse the issuer would be a token whose issuer cannot discharge their legal obligations. **The issuer is the authority, not an adversary the token defends against.**

The consequence, stated plainly: the AGENT/CUSTODIAN separation is an **operational** control, not a cryptographic one. It constrains compromised operational keys. It does not constrain a malicious or compromised issuer admin key, which can assume any role and do anything either role can do.

**Mitigation path, not built here.** A production deployment would keep this authority model and harden its exercise: `DEFAULT_ADMIN_ROLE` behind a multisig, ideally with a timelock, so that self-granting a role or swapping the compliance engine becomes a visible, delayed governance action rather than a single-key transaction. The trust assumption stays; what changes is that acting on it is observable and contestable before it takes effect. That is governance infrastructure, orthogonal to the architecture this POC demonstrates, and deliberately out of scope.

## Build and test

Requires [Foundry](https://book.getfoundry.sh/getting-started/installation).

```bash
git clone --recurse-submodules <repo-url>
cd rwa-security-token
forge build
forge test
```

Formatting (enforced in CI): `forge fmt`.

> At the current stage `forge test` reports no tests found: the interfaces carry no behavior to test. Tests land with each implementation unit, alongside its coverage report. See [Implementation status](#implementation-status).

## License

MIT. Unaudited, educational, not for production use.
