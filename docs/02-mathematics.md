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
8. [Dividend accrual without enumeration](#8-dividend-accrual-without-enumeration)

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

Two freeze concepts coexist on the `SecurityToken`, and their interaction with transfers and burns is small integer arithmetic worth stating precisely.

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

## 8. Dividend accrual without enumeration

`DividendDistributor` pays income pro-rata across every holder. It is the same shape of problem as the holder count in section 5 — a quantity defined over the whole holder set, maintained without ever iterating it — but the quantity here is money, so being one wei wrong in the wrong direction makes the contract insolvent rather than merely imprecise.

### 8.1 Three operations, only two of which move money

The most common misreading of this module is that its transfer hook pays dividends. It does not. Three separate operations exist, and the hook is the only one that touches no funds at all:

| Operation | Caller | When | Moves currency? |
|:---|:---|:---|:---|
| `deposit(amount)` | Issuer (`AGENT_ROLE`) | On collecting rent or interest | Yes, in |
| `claim(to)` | Each holder, independently | Whenever they choose | Yes, out |
| `moduleCreated` / `moduleDestroyed` / `moduleTransferred` | The engine, automatically | On every balance change | **No** |

The hooks are bookkeeping. They adjust one number per affected account so that the payout formula stays true, and nothing else.

### 8.2 How a balance change reaches the module

Nobody calls the module on purpose. The chain is the one every compliance module sits on:

```
alice: token.transfer(bob, 100)
  └─ SecurityToken._update(alice, bob, 100)     ← OZ v5 routes mint/burn/transfer here
       ├─ super._update(...)                    ← balances settle FIRST
       └─ _compliance.transferred(alice, bob, 100)
            └─ for each registered module: moduleTransferred(alice, bob, 100)
                 └─ DividendDistributor
```

Two properties of this path do the real work. The hook fires **after** balances settle, so the module can read final state rather than reconstruct it. And it carries only `from`, `to`, `amount` — the movement, not the holder set. No other account is touched, and none needs to be.

### 8.3 The accumulator and the correction

One global running total, `dividendsPerShare`, rises on each deposit by `amount / totalSupply`. It is denominated in **currency per token**, not in tokens — the single detail that makes the rest of the arithmetic read correctly. An account's lifetime entitlement is then

```
accumulated(a) = balanceOf(a) × dividendsPerShare − correction(a)
```

The first term prices an account's **current** balance as if it had been held since inception. That is false for anyone whose balance ever changed, and `correction(a)` is exactly the accumulated error in that pretence, so the difference is the truth.

The rule on any balance change of `amount` at accumulator value `p` is that `accumulated` must not move: acquiring or disposing of tokens is not an income event. That single rule generates all three hooks.

| Hook | Event | Correction | Why |
|:---|:---|:---|:---|
| `moduleCreated(to, amount)` | Mint | `correction[to] += amount × p` | New tokens must not be paid for deposits that predate them |
| `moduleDestroyed(from, amount)` | Burn | `correction[from] -= amount × p` | Income already earned survives the shares that earned it |
| `moduleTransferred(from, to, amount)` | Transfer | both of the above | The seller keeps what accrued; the buyer is not paid for it |

Mint and burn are the **one-sided cases** of the transfer, which is why the transfer is exactly their sum. Because the two legs are equal and opposite, the sum of `accumulated` over all accounts is untouched by any move. Only `deposit` ever raises it — which is the whole solvency argument in one sentence.

Corrections are therefore signed (`int256`), and the sign has a plain reading:

- **Positive** — "I arrived late; subtract what the formula credits me for a past I did not hold through."
- **Negative** — "I left; add back what the formula no longer sees in my balance."

A negative correction is how a holder who sold, or whose tokens were burned, still claims income earned while holding, with a balance of zero.

### 8.4 The correction is a constant, not a recurring discount

A correction is fixed at the moment of the balance change and never touched again. It does **not** dampen future income. Between any two deposits:

```
Δaccumulated(a) = balanceOf(a) × Δ dividendsPerShare
```

The correction cancels out of the difference because it did not change. What an account earns from a deposit depends only on its balance at that moment — which is precisely the intended rule.

Worked, with a holder minted 100 tokens when the accumulator already stood at 5:

| Event | `dividendsPerShare` | `correction` | `accumulated` |
|:---|---:|---:|---:|
| Mint 100 | 5 | `+500` | `100×5 − 500 = 0` |
| Deposit (→ 8) | 8 | `+500` | `100×8 − 500 = 300` |
| Deposit (→ 12) | 12 | `+500` | `100×12 − 500 = 700` |

300 is `100 × 3`, and 700 − 300 is `100 × 4`. The late arrival collects every subsequent deposit in full, at the same per-token rate as a holder from inception. Buying more works the same way — each lot folds its own entry point into the aggregate correction, with no per-lot history stored:

| Event | `dividendsPerShare` | `correction` | `accumulated` |
|:---|---:|---:|---:|
| Holds 100 | 8 | `+500` | 300 |
| Buy 50 more | 8 | `500 + 50×8 = 900` | `150×8 − 900 = 300` (unchanged: buying pays nothing) |
| Deposit (→ 12) | 12 | `+900` | `150×12 − 900 = 900` |

The gain is 600 = `150 × 4`: both lots earn on the new deposit.

Equivalently, `correction` is a per-wallet zero mark, and the formula is `balance × (dividendsPerShare_now − dividendsPerShare_at_entry)`. Carrying it as a running total rather than a snapshot is what lets it stay exact across arbitrarily many balance changes at arbitrary accumulator values.

### 8.5 Pull, not push

Nobody is paid automatically; each holder calls `claim`. This is the same constraint that forbids enumeration, applied to payment: a push to thousands of holders does not fit in a block, and one holder whose wallet rejects the currency would block everyone else's payment. Under pull, a holder who cannot receive harms only themselves.

`claimable(a) = accumulated(a) − withdrawn(a)`, so the withdrawal record is a second per-account number that must stay in step with the correction. Section 8.6 is where the two come apart.

### 8.6 Why recovery needs its own branch

`ModularCompliance.transferred` is blind: an ordinary sale and a `forcedRecovery` reach `moduleTransferred` with arguments of identical shape ([`SecurityToken.sol`](../src/SecurityToken.sol) fires the same hook from both the recovery and the transfer branch of `_update`). Their meaning for anything that accrues value is opposite:

- **Sale** — the seller keeps the accrued income. It is theirs.
- **Recovery** — `from` is a wallet whose keys an attacker holds. Splitting the entitlement leaves the unclaimed income claimable from the compromised wallet: the tokens are rescued and the money is handed over.

Since the distinction does not travel in the hook signature, the module asks the token — `recovering()`, a view over the flag `forcedRecovery` already sets — and carries the position whole instead of splitting it:

```
correction[new] += correction[lost];   withdrawn[new] += withdrawn[lost]
correction[lost] = 0;                  withdrawn[lost] = 0
```

Carrying `withdrawn` matters as much as the correction. Move only the correction and the new wallet inherits the gross entitlement with a zero withdrawal record, re-claiming income the old wallet was already legitimately paid.

This is the one place the distributor depends on the token being a `SecurityToken` rather than any ERC-20. The alternative — a distinct `moduleRecovered` hook on `IComplianceModule` — removes the coupling at the cost of widening the interface for every module; see [Guide 4](./04-tradeoffs.md).

### 8.7 Scale and rounding direction

`amount / totalSupply` truncates to zero for any realistic supply, so the accumulator is scaled by `2**128` and descaled on read. Two roundings remain, handled differently on purpose:

- **The deposit's own truncation is carried, not lost.** The remainder is kept in `residue` in **scaled** units (`scaled % supply`) and folded into the next deposit. Carrying it in currency units instead rounds the dust *up* every deposit and compounds until claims exceed deposits — this was a real bug in this contract, caught by a multi-deposit fuzz property.
- **Each holder's descaling truncates down**, at most one wei each. This is the direction that keeps the contract solvent: the sum of claims sits at or below what was deposited, never above, so the last claimant is never left short.

`deposit` reverts on zero supply rather than accruing to nobody. A consequence worth noting: once the note is fully amortised and supply reaches zero, no further deposit is possible, but everything deposited earlier stays claimable by its holders — who by then hold no tokens at all, and are made whole by their negative corrections.

---

**See also:**
- [Guide 3: Architecture](./03-architecture.md) - where these mechanisms sit in the system
- [Guide 4: Trade-offs](./04-tradeoffs.md) - the lockup-model decision as a trade-off
- [README: registration paths](../README.md#the-two-registration-paths) - the trust argument behind the digest
