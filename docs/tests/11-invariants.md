# Invariant Suite (Phase 6)

**Suites:** [`InvariantsTest`](../../test/invariant/Invariants.t.sol) (7 invariants + 1 reachability test), driven by [`Handler`](../../test/invariant/Handler.sol)
**Covers:** roadmap items 6.2 to 6.3 · [Guide 5, invariants](../05-implementation.md#7-invariants)

---

> The properties that must hold for **any** sequence of calls, not just the hand-picked ones. The unit and scenario suites assert these at points; this suite asserts them across arbitrary interleavings of mint, burn, transfer, both freeze pairs, pause, recovery, identity withdrawal and the passage of time.
>
> It earned its place immediately: it found a live bug in `MaxHoldersModule` that every other layer missed. See [The bug it found](#the-bug-it-found).

## The bug it found

A **self-transfer of a full balance inflated the holder count**:

```
alice holds 100, sole holder     -> holderCount = 1
alice transfers 100 to herself   -> holderCount = 2   <- nobody new appeared
```

The lifecycle hooks infer transitions from post-transfer balances: `balanceOf(to) == amount` means the recipient came from zero, and `balanceOf(from) == 0` means the sender left. With `from == to` and a full-balance send, the first is true while the second is false, so the two signals fail to cancel and the count rises for a holder who never appeared.

**Why it matters.** The count is what enforces the holder cap, and a private placement's cap is a regulatory limit. Anyone could repeat a free self-transfer until the count reached `maxHolders`, at which point no genuine investor could be admitted. A cheap denial of service against the placement itself.

**Why the other layers missed it.** Nobody writes a unit test for sending tokens to yourself, because it does nothing. The scenario suite walks realistic operator sequences, and a self-transfer is not one. Only random sequencing over a bounded actor pool produced `from == to`, and only then because the pool is small enough for the fuzzer to draw the same actor twice.

The fix discards the case at the top of `moduleTransferred`, and two regression tests now pin it: [`test_transfer_selfTransferKeepsCountFlat`](../../test/unit/MaxHoldersModule.t.sol#L133) and [`test_transfer_partialSelfTransferKeepsCountFlat`](../../test/unit/MaxHoldersModule.t.sol#L143). `LockupModule` uses the same inference and was checked for the same flaw: it is immune, because its `_lockStart[to] != 0` guard prevents restarting an existing clock.

---

## The invariants

| Invariant | Statement |
| :--- | :--- |
| [`invariant_balancesSumToTotalSupply`](../../test/invariant/Invariants.t.sol#L108) | Balances across the whole reachable address space sum to `totalSupply` |
| [`invariant_supplyMatchesMintsMinusBurns`](../../test/invariant/Invariants.t.sol#L121) | Supply moves **only** through issuance and retirement, tracked against ghost counters |
| [`invariant_frozenNeverExceedsBalance`](../../test/invariant/Invariants.t.sol#L135) | `frozenTokens[a] <= balanceOf(a)` for every actor |
| [`invariant_holderCountMatchesReality`](../../test/invariant/Invariants.t.sol#L151) | The module's cached count equals the addresses actually holding a balance |
| [`invariant_holderCountNeverExceedsCap`](../../test/invariant/Invariants.t.sol#L164) | The count never exceeds `maxHolders` |
| [`invariant_recoveryLeavesEvictedWalletEmpty`](../../test/invariant/Invariants.t.sol#L183) | Recovery always leaves the wallet it evicted empty, measured at the instant of eviction |
| [`invariant_unverifiedHoldersAreConsistent`](../../test/invariant/Invariants.t.sol#L204) | An unverified wallet has no movable balance and a coherent frozen figure |

Three deserve their reasoning stated.

**Supply conservation is where recovery would show up.** `forcedRecovery` touches balances, freeze state and the registry in one call while bypassing the transfer gate entirely. If its ordering were wrong it would mint or destroy, and the ghost-tracked `minted - burned` is what would catch it.

**The cap is not implied by the gate.** Recovery skips `moduleCheck`, so nothing stops it raising the count on the way past — nothing except the fact that a recovery always empties the lost wallet in the same movement that fills the new one. The invariant asserts the consequence rather than trusting the argument.

**The eviction property is measured at the right moment.** An earlier version asserted "an evicted wallet that is currently unverified holds nothing", and the fuzzer disproved it with an entirely correct sequence: evict the wallet, re-onboard it, let it receive a transfer, then withdraw the identity again. Nothing was wrong with the system; the invariant was asking about a later state that says nothing about recovery. Recording the balance at the instant the eviction completed asks the question that actually belongs to `forcedRecovery`.

**"Verified holders only" is deliberately weaker than it sounds.** It is *not* "no unverified address holds a balance", which is false by design: `removeIdentity` suspends a live position rather than confiscating it, so an unverified wallet keeps what it had. What the gate guarantees is that the balance cannot **grow**, and that it cannot move. Asserting the stronger form would be asserting a property the system deliberately does not have.

---

## The handler

[`Handler.sol`](../../test/invariant/Handler.sol) exposes ten actions over a fixed pool of six wallets.

| Action | Notes |
| :--- | :--- |
| [`mint`](../../test/invariant/Handler.sol#L147) / [`burn`](../../test/invariant/Handler.sol#L160) | Issuance and retirement, tracked in ghost counters |
| [`transfer`](../../test/invariant/Handler.sol#L173) | Amount bound against the sender's real balance |
| [`setAddressFrozen`](../../test/invariant/Handler.sol#L186) | Full freeze, both directions |
| [`freezePartialTokens`](../../test/invariant/Handler.sol#L196) / [`unfreezePartialTokens`](../../test/invariant/Handler.sol#L209) | Bound against the free and frozen portions respectively |
| [`togglePause`](../../test/invariant/Handler.sol#L242) | Throttled, see below |
| [`forcedRecovery`](../../test/invariant/Handler.sol#L266) | Most draws are correctly rejected: the two actors rarely share an investor id |
| [`toggleIdentity`](../../test/invariant/Handler.sol#L300) | Withdrawal and restoration, throttled |
| [`warp`](../../test/invariant/Handler.sol#L329) | Time passes, so the lockup boundary is crossed in both directions |

### Why the pool is fixed

Actors are drawn from six fixed wallets rather than fuzzed addresses. With free addresses almost every transfer would find an empty sender and revert, and the fuzzer would spend its whole budget rediscovering that strangers hold nothing. Two pairs share an investor id so recovery has valid destinations; the remaining two are their own investors so invalid recoveries are exercised too.

The small pool is also what surfaced the self-transfer bug: it makes `from == to` a likely draw rather than an astronomically improbable one.

### Why two actions are throttled

This is the part that took the most iteration, and it generalises beyond this project.

`pause` and `removeIdentity` are **absorbing**: once taken, they block most other actions until explicitly undone. As independent actions, the fuzzer would enter a paused or fully-unverified state within a few draws and then spend the remaining depth watching every balance-moving call revert. The invariants would all hold, over a system that did nothing.

Both are therefore toggles that enter their blocking state on a fraction of draws and leave it unthrottled, keeping the state reachable but short-lived. Recovery's exemption from the pause is still exercised, because recovery draws land inside those stretches.

### Why the counters exist

The suite runs with `fail_on_revert = false`. This is necessary — a locked-up transfer *must* be allowed to revert — and it is exactly how an invariant suite silently tests nothing: if every call reverted, every invariant would hold vacuously and the run would still be green.

Each action increments a counter only on success, and [`test_handlerExercisesEveryAction`](../../test/invariant/Invariants.t.sol#L241) drives every action against a known-good state and asserts its counter moved. It is not a nicety: it caught two real defects in the handler during development, one where a `vm.prank` was consumed by a state-reading call before reaching the call it was meant to authorise, and one where a throttle read an already-bounded parameter and so **never withdrew an identity at all**.

**Note on placement.** The counters cannot be asserted in `afterInvariant`, which does not observe the state a sequence accumulated and reads zero regardless. The guarantee lives in the deterministic reachability test instead. [`afterInvariant`](../../test/invariant/Invariants.t.sol#L226) is kept purely as a `-vv` readout of what a run exercised.

---

## Configuration

The suite wires the system by hand rather than inheriting [`Deploy`](../../script/Deploy.s.sol), for two reasons:

- **A 7-day lockup instead of 365.** With a year-long period almost every transfer in a run would be rejected by the same rule, exploring one branch deeply and everything else not at all.
- **A holder cap of 4 instead of 499.** The cap has to be *reachable* within a run for its enforcement branch to be exercised at all.

Everything else matches the real deployment: the same engine, the same registry, all three rule modules, the same role separation.

```bash
forge test --match-path "test/invariant/*"                  # 64 runs x 64 depth
FOUNDRY_INVARIANT_RUNS=300 FOUNDRY_INVARIANT_DEPTH=100 \
  forge test --match-path "test/invariant/*"                # 30,000 calls per invariant
```

The high-effort run is what surfaced the holder-count bug, and is the configuration to use before trusting a change to the modules or the gate.
