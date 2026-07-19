# 🔢 Guide 2: Mathematics & Cryptography

**Version:** 1.0
**Prerequisites:** [Guide 1: Fundamentals](./01-fundamentals.md)
**Next:** [Guide 3: Architecture](./03-architecture.md)

---

## 📋 Table of Contents

1. [Why this guide exists](#1-why-this-guide-exists)
2. [The EIP-712 attestation digest](#2-the-eip-712-attestation-digest)
3. [Replay: the three axes and what closes each](#3-replay-the-three-axes-and-what-closes-each)
4. [Storage packing of the identity record](#4-storage-packing-of-the-identity-record)
5. [Holder-count transitions without enumeration](#5-holder-count-transitions-without-enumeration)
6. [The lockup clock](#6-the-lockup-clock)
7. [Freeze and burn arithmetic](#7-freeze-and-burn-arithmetic)

---

## 1. Why this guide exists

A security token has almost no financial mathematics: no PnL, no interest accrual on-chain, no curve. What it has instead is **cryptographic and bookkeeping mathematics**, and those are where the subtle correctness properties hide. This guide covers the digest that authorizes an off-chain identity, the bit-level record layout, and the small integer arithmetic that tracks holders, lockups, and freezes without ever iterating an unbounded set.

---

## 2. The EIP-712 attestation digest

The permissionless registration path (`registerIdentityWithAttestation`) accepts a record from anyone, on the strength of a signature from the authorized claim signer. The signature is over an **EIP-712 typed-data digest**, not a raw hash, so wallets can display the structured fields and the signature is bound to this contract on this chain.

### 2.1 The type hash

```solidity
bytes32 public constant ATTESTATION_TYPEHASH = keccak256(
    "IdentityAttestation(address investor,uint16 country,bool accredited,uint64 kycExpiry,uint256 nonce)"
);
```

The type hash is `keccak256` of the canonical type string. Five fields are signed: the investor, the three attested attributes, and the nonce.

### 2.2 The digest

The full EIP-712 digest is:

```
digest = keccak256(
    0x19 ‖ 0x01
    ‖ domainSeparator
    ‖ keccak256(ATTESTATION_TYPEHASH ‖ investor ‖ country ‖ accredited ‖ kycExpiry ‖ nonce)
)
```

where `‖` is `abi.encode` concatenation (each field padded to 32 bytes) and `domainSeparator` is:

```
domainSeparator = keccak256(
    keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)")
    ‖ keccak256("IdentityRegistry") ‖ keccak256("1") ‖ chainId ‖ address(this)
)
```

In the contract this is assembled by OpenZeppelin's `EIP712._hashTypedDataV4`:

```solidity
bytes32 digest = _hashTypedDataV4(
    keccak256(abi.encode(ATTESTATION_TYPEHASH, investor, country_, accredited, kycExpiry, usedNonce))
);
address recovered = digest.recover(signature);
if (recovered != signer) revert InvalidAttestationSigner(recovered, signer);
```

The `chainId` and `verifyingContract` inside the domain separator are what make the signature specific to this deployment. That is the mathematical fact the next section leans on.

---

## 3. Replay: the three axes and what closes each

A signed authorization is a bearer object: whoever holds it can submit it. The design has to make sure a valid signature can be used **exactly once, here, and only while it should be valid**. Three independent axes, three independent closures:

| Replay axis | Attack | What closes it | Where |
|:---|:---|:---|:---|
| **Space** | Submit the same signature on another chain, or against another registry deployment | `chainId` + `verifyingContract` in the domain separator produce a different `digest` off this deployment | EIP-712 domain |
| **Time** | Submit a signature after the KYC has lapsed | `kycExpiry` is checked (`isVerified` and `_register` both reject stale) | `kycExpiry` field + check |
| **Sequence** | Re-submit a still-valid signature to re-register an investor the agent just removed | Per-investor `nonce`, consumed before verification | `nonce` field + `_nonces` |

The **sequence axis** is the subtle one and worth the arithmetic. The nonce is consumed by post-increment *before* the digest is built:

```solidity
uint256 usedNonce = _nonces[investor]++;   // read current, then increment stored
// ... digest signed over usedNonce ...
```

Suppose the current stored nonce is `n`. A legitimate attestation was signed over nonce `n`.

1. First submission: `usedNonce = n`, stored becomes `n+1`. Digest matches the signature, signer check passes, record written.
2. Replay of the same payload: `usedNonce = n+1`, stored becomes `n+2`. The digest is now computed over `n+1`, but the signature was over `n`. `recover` returns **a different address**, the signer check fails, revert.

The nonce is consumed as an *effect before the check* on purpose (CEI-friendly, and it means even a reverting inner path cannot leave the nonce reusable). Because the recovered address is unpredictable on a replay, tests assert this with `expectPartialRevert` on the `InvalidAttestationSigner` selector rather than matching exact parameters.

Expiry alone would **not** close the sequence axis: within the validity window, the same signature would keep re-registering a just-removed investor. That is precisely the hole the nonce exists to close, and why it is not optional.

---

## 4. Storage packing of the identity record

The `Identity` record is read on every transfer (the recipient must be verified), so it is laid out to occupy **one storage slot**, one `SLOAD`:

```solidity
struct Identity {
    bool verified;     //  1 byte  ─┐
    bool accredited;   //  1 byte   │
    uint16 country;    //  2 bytes  │  Slot 0 (12 bytes used, 20 free)
    uint64 kycExpiry;  //  8 bytes ─┘
}
```

The field order matters. Solidity packs sequential fields into a slot right-to-left as long as they fit in 32 bytes; `1 + 1 + 2 + 8 = 12 ≤ 32`, so all four share slot 0. Reordering would not break packing here (there is ample room), but keeping the small flags adjacent is the idiomatic layout and leaves the free 20 bytes contiguous for a future field.

Two design points ride on the field widths:

- **`country` as `uint16`** holds an ISO 3166-1 numeric code (max 894), not a string. The country restriction rule compares integers, never parses bytes.
- **`kycExpiry` as `uint64`** is a Unix timestamp; `uint64` covers to year 584942, so no overflow concern, and it keeps the whole record in one slot.

> Packing is verified, not asserted: `forge inspect storageLayout` confirms the four fields share slot 0. This is a project convention (see the workflow notes), not a claim taken on faith.

---

## 5. Holder-count transitions without enumeration

`MaxHoldersModule` caps the number of distinct holders. The naive implementation counts holders by enumerating balances, which is unbounded gas. Instead the count is maintained **incrementally in the lifecycle hooks**, which run *after* balances have already moved. Because balances are already updated, a transition can be inferred from a single `balanceOf`:

| Observation after the hook fires | Meaning | Count effect |
|:---|:---|:---|
| `balanceOf(to) == amount` | Recipient held zero before; they just joined | `count + 1` |
| `balanceOf(from) == 0` | Sender sent their whole balance; they just left | `count - 1` |

On a transfer both can happen, and the arithmetic composes cleanly:

```
Δcount = [recipient joined ? +1 : 0] + [sender left ? -1 : 0]
```

The four cases:

```
                          recipient was new?
                        ┌──────────┬──────────┐
                        │   yes    │    no    │
        ┌───────────────┼──────────┼──────────┤
        │ sender        │  Δ = 0   │  Δ = -1  │   ← sender emptied
 sender │ emptied?  yes │(swap)    │          │
  left? ├───────────────┼──────────┼──────────┤
        │           no  │  Δ = +1  │  Δ =  0  │
        └───────────────┴──────────┴──────────┘
                          ↑ new holder      ↑ both already held
```

The **swap case (`Δ = 0`)** is the one that makes the cap usable. If a full-balance transfer at the cap were rejected, the token would deadlock: at max holders, nobody could ever move their whole position to a new investor. Because a sender emptying and a recipient joining net to zero, one holder can replace another at the cap. A *new* holder joining while nobody leaves is the only case the cap rejects.

Two guards keep the count honest:

- The cap **cannot be set below the live count** (`setMaxHolders` reverts otherwise), or the invariant "count ≤ cap" would be violated retroactively.
- The count is only ever mutated in hooks, which are `onlyCompliance`, so it cannot desync from real balances.

---

## 6. The lockup clock

`LockupModule` enforces a holding period. The arithmetic is a single comparison, but the *state machine* around it is where the security property lives.

### 6.1 The check

```solidity
function moduleCheck(address from, address, uint256) external view returns (bool) {
    if (from == address(0)) return true;              // mint is acquisition, not disposal
    uint64 start = _lockStart[from];
    if (start == 0) return true;                       // no clock ⇒ nothing to restrain
    return block.timestamp >= start + _lockupPeriod;   // unlocked once the window elapses
}
```

`unlocksAt = lockStart + lockupPeriod`, and the sender may dispose once `block.timestamp ≥ unlocksAt`.

### 6.2 The clock state machine

The clock is a per-investor `uint64` timestamp; `0` means "no position, no clock". Three transitions:

```
        mint / receive         (holds, clock running)      exit to zero
  0 ──────────────────────►  lockStart = t  ──────────────────────► 0
        (balance 0 → +)                                 (balance + → 0)
                                    ▲
                                    │ later receipts:
                                    │ lockStart already ≠ 0 ⇒ NO overwrite
                                    └──────────────────────────────
```

- **Start** (`_startClockIfNew`): only on the `0 → positive` transition, identified by `balanceOf(to) == amount` after the hook. The one-line guard `if (_lockStart[to] != 0) return;` is the anti-griefing property.
- **Clear** (`_clearClockIfExited`): on `positive → 0`, so an investor who sells out and rebuys later is locked afresh instead of keeping a long-expired clock.

### 6.3 Why the guard is a security property, not a convenience

Consider the alternative, a strict per-acquisition lockup where every receipt restarts the clock. On a fungible balance that is exploitable:

```
Attacker sends victim 1 wei
        │
        ▼
lockStart[victim] ← now        ⇒  victim's ENTIRE position re-locked for the full period
        │
        └── cost to attacker: one dust transfer. Repeatable forever.
```

A lockup a hostile third party can trigger against you, for free, is a denial of service wearing a compliance costume. The `lockStart != 0 ⇒ don't overwrite` guard makes the clock **monotonic per holding**: it starts once and is never pushed forward by an incoming transfer.

The strictly-correct per-acquisition reading would lock each *parcel* separately, which requires per-parcel accounting: exactly what ERC-1400 partitions provide, and exactly what is out of scope here. Without partitions, "from initial acquisition" is the safe model, and the anchored terms document is worded to match. This is the project's flagship example of a scope decision determining a security property; the full argument is in the [README](../README.md#why-the-lockup-runs-from-initial-acquisition-not-from-each-acquisition).

---

## 7. Freeze and burn arithmetic

Two freeze concepts coexist on the (designed) `SecurityToken`, and their interaction with transfers and burns is small integer arithmetic worth stating precisely.

- **Full freeze:** a boolean per wallet. A fully frozen wallet can neither send nor receive.
- **Partial freeze:** an amount `frozen[investor] ≤ balanceOf(investor)`. On a normal transfer, only the **unfrozen** portion may move:

```
transferable(from) = balanceOf(from) − frozen[from]
require: amount ≤ transferable(from)     else InsufficientUnfrozenBalance
```

Burn is the deliberate exception. The issuer retiring a position **outranks** an operational freeze, so burn eats the unfrozen balance first and reduces the frozen amount only if it must:

```
if amount > balanceOf(from) − frozen[from]:
    frozen[from] ← frozen[from] − (amount − (balanceOf(from) − frozen[from]))
```

Forced recovery preserves the freeze arithmetic across wallets: it carries **both** `frozen[lost]` and the full-freeze flag to the new wallet, then zeroes the lost wallet. This is what stops recovery from being used to launder a freeze, and it keeps `Σ balances == totalSupply` invariant because the move is a pure reassignment, never a mint or burn. These behaviors are specified in `ISecurityToken` and land with Phase 4; see [Guide 5](./05-implementation.md).

---

**See also:**
- [Guide 3: Architecture](./03-architecture.md) - where these mechanisms sit in the system
- [Guide 4: Trade-offs](./04-tradeoffs.md) - the lockup-model decision as a trade-off
- [README: registration paths](../README.md#the-two-registration-paths) - the trust argument behind the digest
