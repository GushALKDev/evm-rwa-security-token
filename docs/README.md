# 📚 Documentation Index: EVM RWA Security Token

**Version:** 1.0
**Status:** Portfolio / educational proof-of-concept (unaudited)

---

## 🎯 Quick Start

| Document | Description | Status |
| :------- | :---------- | :----- |
| **[Project README](../README.md)** | Overview, scoping decisions, role matrix, threat model, build instructions | ✅ Complete |
| **[ROADMAP](./ROADMAP.md)** | Eight-phase implementation plan and progress tracker | ✅ Complete |
| **[Terms document](./RealEstateNote-Terms.md)** | The legal instrument the token represents, anchored on-chain by content hash | ✅ Complete |
| **[LICENSE](../LICENSE)** | MIT License | ✅ Complete |

> The project README is the **narrative source of truth**. The guides below go deeper on specific topics and deliberately reference the README rather than repeating its scoping and threat-model arguments.

---

## 📖 Technical Guides

### Core Concepts (Start Here)

1. **[Fundamentals](./01-fundamentals.md)**
    - What the project is, and what an ERC-3643 subset means
    - The asset (a real-estate-backed note) and why it drives every design decision
    - The core inversion: permission by default, not balance by default
    - The four moving parts and how they relate
    - Glossary of terms

2. **[Mathematics & Cryptography](./02-mathematics.md)**
    - The EIP-712 attestation digest, field by field
    - Replay: the three axes (space, time, sequence) and what closes each
    - Storage packing of the identity record
    - Holder-count transitions without enumeration
    - The lockup clock state machine and the anti-griefing guard
    - Freeze and burn arithmetic

### Architecture & Implementation

3. **[Architecture](./03-architecture.md)**
    - System overview and the two structural invariants
    - The identity registry and its two registration doors
    - The compliance engine, module integrity, and the pluggable seam
    - The transfer gate as a superset check (one implementation, two callers)
    - Lifecycle hooks and state consistency
    - Document anchoring
    - Deployment order and the binding graph

4. **[Trade-offs](./04-tradeoffs.md)**
    - Scope decisions (ONCHAINID collapse, single claim signer, no partitions, no proxies)
    - Design decisions inside the built code
    - Accepted risks (issuer authority, custodian blast radius, projection vs truth)
    - Trade-off summary table

5. **[Implementation](./05-implementation.md)**
    - Build order, status, and source layout
    - Coding conventions (custom errors, CEI, NatSpec, naming)
    - OpenZeppelin primitives used and why
    - Key implementation patterns
    - Testing strategy (negative tests, verified claims, fuzzing)
    - Deployment and hash anchoring
    - System invariants

### Advanced Topics

6. **[Improvements](./06-improvements.md)**
    - Restoring the ERC-3643 identity hierarchy
    - Partitions and a strict per-acquisition lockup
    - Governance hardening (multisig, timelock)
    - Upgradeability and factory
    - Dividend distribution (the planned stretch unit)
    - Operational and tooling improvements, with a priority table

### Verification

7. **[Testing Documentation](./tests/README.md)** — a section, not a single guide
    - [Strategy](./tests/01-strategy.md): layers, principles, mocks, how to run the suite
    - One document per suite, cataloguing every test with a link to its code
    - Invariant coverage map: each property and what currently asserts it
    - [Invariant Suite](./tests/11-invariants.md): the bounded handler and the holder-count bug it found
    - [Gaps & Roadmap](./tests/12-gaps-and-roadmap.md): what is not covered, and which phase closes it

---

## 🗂️ Documentation Structure

```
docs/
├── README.md                    # This file
├── ROADMAP.md                   # Implementation phases and progress
├── RealEstateNote-Terms.md      # The anchored legal instrument
│
├── 01-fundamentals.md           # Start here
├── 02-mathematics.md            # Digest, packing, rule arithmetic
├── 03-architecture.md           # System design and wiring
├── 04-tradeoffs.md              # Decisions and accepted risks
├── 05-implementation.md         # Conventions, patterns, testing
├── 06-improvements.md           # What production would add back
└── tests/                       # Testing section: strategy, per-suite catalogue, gaps
```

---

## 🎓 Recommended Reading Order

### For Developers

1. [Fundamentals](./01-fundamentals.md) - understand the model
2. [Architecture](./03-architecture.md) - see how the parts wire together
3. [Mathematics & Cryptography](./02-mathematics.md) - the mechanisms in detail
4. [Implementation](./05-implementation.md) - conventions and patterns
5. [ROADMAP](./ROADMAP.md) - what is built and what is next

### For Auditors

1. [Architecture](./03-architecture.md) - system overview and trust boundaries
2. [Mathematics & Cryptography](./02-mathematics.md) - replay closure and rule arithmetic
3. [Project README: threat model](../README.md#threat-model) - access-control model and accepted risks
4. [Trade-offs](./04-tradeoffs.md) - known limitations, stated deliberately
5. [Implementation](./05-implementation.md) - invariants and testing strategy
6. [Testing Documentation](./tests/README.md) - the invariant coverage map, then the per-suite catalogue

### For Reviewers Assessing Design Judgement

1. [Project README: standards and scoping](../README.md#standards-and-scoping) - what was cut and why
2. [Trade-offs](./04-tradeoffs.md) - the decision register
3. [Mathematics §6: the lockup clock](./02-mathematics.md#6-the-lockup-clock) - where a scope decision determined a security property
4. [Improvements](./06-improvements.md) - the map back to a production instrument

---

## 📊 Progress Tracking

See [ROADMAP.md](./ROADMAP.md) for detailed progress across 8 phases and 35 trackable items.

**Current status:** Phases 0 to 6 complete (foundations, identity, compliance, document anchoring, the token, deployment, and the scenario plus invariant suites).

**Test suite:** 258 tests passing, 100% line/statement/branch/function coverage on every `src/` contract. See the [testing section](./tests/README.md) for what each block covers.

---

## 🔗 External Resources

- **ERC-3643 (T-REX):** https://eips.ethereum.org/EIPS/eip-3643 (the standard this implements a subset of)
- **T-REX reference implementation:** https://github.com/TokenySolutions/T-REX (what production would build on)
- **ERC-1400 family:** https://github.com/ethereum/EIPs/issues/1411 (partitions, out of scope here)
- **ERC-1643:** https://github.com/ethereum/EIPs/issues/1643 (document anchoring)
- **EIP-712:** https://eips.ethereum.org/EIPS/eip-712 (typed structured data signing)
- **OpenZeppelin Contracts:** https://docs.openzeppelin.com/contracts/5.x/ (every primitive used)
- **Foundry Book:** https://book.getfoundry.sh/

---

## ⚖️ License

MIT, see [LICENSE](../LICENSE). Unaudited, educational, not for production use or for representing real financial instruments.

---

**Maintained by:** @GushALKDev (portfolio project)
