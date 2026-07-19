# 📘 Guide 1: Fundamentals

**Version:** 1.0
**Next:** [Guide 2: Mathematics & Cryptography](./02-mathematics.md)

---

## 📋 Table of Contents

1. [What this project is](#1-what-this-project-is)
2. [The asset and why it drives the design](#2-the-asset-and-why-it-drives-the-design)
3. [The core inversion: permission by default](#3-the-core-inversion-permission-by-default)
4. [The four moving parts](#4-the-four-moving-parts)
5. [The on-chain / off-chain boundary](#5-the-on-chain--off-chain-boundary)
6. [Glossary](#6-glossary)

---

> This guide is the conceptual entry point. It does not re-argue the scoping decisions or the access-control threat model in depth: those live in the [README](../README.md), which is the narrative source of truth. Where a topic is fully covered there, this guide summarizes and links rather than duplicating.

---

## 1. What this project is

A proof-of-concept for **compliant tokenization of a real-world financial asset** as a permissioned security token. It implements a coherent subset, written from scratch on OpenZeppelin v5 primitives, of the identity and compliance model standardized by **ERC-3643 (T-REX)**, plus document anchoring borrowed from **ERC-1643**.

The goal is not to deploy the standard. Audited reference implementations already exist ([`@tokenysolutions/T-REX`](https://github.com/TokenySolutions/T-REX)). The goal is to demonstrate understanding of the architecture by rebuilding the parts that carry the security properties, and being explicit about which parts were left out and why.

---

## 2. The asset and why it drives the design

The token represents a **Series A real-estate-backed note**: a debt instrument secured by a residential property in Valencia, Spain, held through an SPV, issued to a whitelist of accredited investors. Face value 1,000 EURC per token, 36-month maturity. The governing terms live in [`RealEstateNote-Terms.md`](./RealEstateNote-Terms.md) and are anchored on-chain by content hash.

The asset choice is not decoration. A note is a claim on a real property against a real issuer, enforceable in a real court, and that single fact drives every design decision:

| Because the asset is... | The token must... |
|:---|:---|
| A regulated security | Restrict transfers to KYC-verified investors, because securities law restricts them |
| Subject to court orders | Support freezing balances (full and partial) |
| A legal claim that outlives a key | Support moving a position out of a lost wallet without changing supply |
| Governed by a written indenture | Anchor that document by hash, so an amendment is detectable |

A plain ERC-20 has no concept of any of these. That is the entire reason a security token is a distinct thing.

---

## 3. The core inversion: permission by default

A plain ERC-20 answers one question: *does the sender have the balance?* A security token answers a different one: **is this specific transfer, between these two specific parties, legal right now?**

That inverts the default. In an ERC-20, transfers are permitted unless the balance is insufficient. Here, transfers are **forbidden unless identity and compliance both approve**.

```
        ERC-20                          Security Token
    ┌───────────────┐              ┌──────────────────────────┐
    │ balance ok?   │              │ not paused?              │
    │   ├─ yes → OK │              │ recipient verified?      │
    │   └─ no  → ✗  │              │ sender not frozen?       │
    └───────────────┘              │ recipient not frozen?    │
                                   │ unfrozen balance enough? │
     "allowed unless               │ all compliance modules   │
      you can't"                   │        approve?          │
                                   │   ├─ all yes → OK        │
                                   │   └─ any no  → revert    │
                                   └──────────────────────────┘
                                     "forbidden unless
                                      everything approves"
```

The ERC-20 interface is preserved so existing tooling can read balances and build transfers. The semantics underneath differ, and a wallet assuming ERC-20 semantics will see reverts it does not expect. **That revert is the compliance boundary doing its job.**

> The full ERC-20-vs-security-token comparison table is in the [README](../README.md#why-a-permissioned-token-is-not-an-erc-20).

---

## 4. The four moving parts

The system is four cooperating contracts, built in dependency order. Only the last one is the token.

```
┌──────────────────────────────────────────────────────────────────┐
│                         SecurityToken                            │
│  ERC-20 shape + issuer powers (mint, burn, freeze, recovery)    │
│  Every _update passes through the transfer gate ───────┐        │
└──────────────────┬─────────────────────────┬───────────┼────────┘
                   │ "is the recipient       │ "do the   │
                   │  allowed to hold?"      │  rules    │ "which document
                   ▼                         │  pass?"   │  is in force?"
        ┌────────────────────┐               ▼           ▼
        │  IdentityRegistry  │     ┌───────────────────┐ ┌──────────────────┐
        │  KYC projection,   │     │ ModularCompliance │ │ DocumentRegistry │
        │  two write paths   │     │  composes modules │ │  hash + URI      │
        └────────────────────┘     └─────────┬─────────┘ └──────────────────┘
                                             │ fans hooks to
                              ┌──────────────┼──────────────┐
                              ▼              ▼              ▼
                       ┌───────────┐  ┌────────────┐  ┌──────────┐
                       │MaxHolders │  │  Country   │  │  Lockup  │
                       │  Module   │  │Restriction │  │  Module  │
                       └───────────┘  └────────────┘  └──────────┘
```

| Contract | Question it answers | Status |
|:---|:---|:---|
| **IdentityRegistry** | May this address hold the token, and is that still true? | Built |
| **ModularCompliance** | Do the plugged-in rules permit this transfer? | Built |
| **Compliance modules** | One rule each (holder cap, jurisdiction, lockup) | Built |
| **DocumentRegistry** | Which exact terms document is in force? | Designed |
| **SecurityToken** | Compose all of the above into a gated ERC-20 | Designed |

The key structural choice: **the token references the engine, never the individual modules.** Changing the rule set is a governance action (add or remove a module) rather than a token redeploy. See [Guide 3](./03-architecture.md) for how this seam is wired.

---

## 5. The on-chain / off-chain boundary

The contracts are not the system. They are the enforcement surface of a system that mostly lives off-chain, and being precise about that line is most of the architecture.

Two properties of the boundary are worth stating up front, because everything else follows from them:

1. **On-chain data is a projection, not a source of truth.** `isVerified` returning true does not mean an investor passed KYC. It means someone *attested* that they did, and the attestation has not expired. This is why `kycExpiry` exists: a permanent `verified` flag would quietly become a lie.

2. **The document hash is of the content, not the URI.** The URI says where the terms live; the hash proves which exact bytes are in force. If the issuer silently amends the terms, the hash stops matching and the substitution is evident on-chain.

> The full boundary table (what lives off-chain, how it crosses, how it is enforced) is in the [README](../README.md#on-chain-and-off-chain-boundary).

---

## 6. Glossary

| Term | Definition |
|:---|:---|
| **Security token** | A token representing a regulated financial instrument, whose transfers are legally restricted. |
| **ERC-3643 (T-REX)** | The permissioned-token standard this project implements a subset of: identity registry + modular compliance + gated transfer. |
| **ERC-1643** | Document-management standard (from the ERC-1400 family); the source of the anchoring pattern. |
| **ONCHAINID** | ERC-3643's per-investor on-chain identity contract holding signed claims. Collapsed into a flat registry here (see [README](../README.md#what-was-deliberately-left-out-and-why)). |
| **Attestation** | A signed statement (EIP-712 payload) that an investor passed KYC, with a shelf life (`kycExpiry`). |
| **Claim signer** | The single authorized address whose signature the registry trusts on the attestation path. |
| **Compliance module** | A single pluggable transfer rule (holder cap, jurisdiction, lockup) registered on the engine. |
| **Lifecycle hook** | A post-transfer callback (`transferred`/`created`/`destroyed`) letting stateful modules update. |
| **Forced recovery** | Custodian-only move of a full position from a lost wallet to a new verified one, supply unchanged. |
| **Full / partial freeze** | Immobilizing an entire wallet, or a portion of a balance (a disputed lot, a pledge). |
| **ISSUER / AGENT / CUSTODIAN** | The three roles: supply & config / compliance operations / recovery. See the [README matrix](../README.md#role-and-permission-matrix). |

---

**See also:**
- [Guide 2: Mathematics & Cryptography](./02-mathematics.md) - the EIP-712 digest, holder-count transitions, the lockup clock
- [Guide 3: Architecture](./03-architecture.md) - how the four parts wire together
- [Project README](../README.md) - scoping decisions and threat model in full
