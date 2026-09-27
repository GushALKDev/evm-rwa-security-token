# Invariant Suite (Phase 6)

**Suites:** [`InvariantsTest`](../../test/invariant/Invariants.t.sol) (12 invariants + 1 deterministic test), driven by [`Handler`](../../test/invariant/Handler.sol)
**Covers:** roadmap items 6.2 to 6.3 · [Guide 5, invariants](../05-implementation.md#7-invariants)

---

> The properties that must hold for **any** sequence of calls, not just the hand-picked ones. The unit and scenario suites assert these at points; this suite asserts them across arbitrary interleavings of mint, burn, transfer, approve and `transferFrom`, both freeze pairs, pause, forced recovery, identity withdrawal, the country block, dividend deposits and claims, and the passage of time.
>
> It found a live bug in `MaxHoldersModule` that every other layer missed, see [The bug it found](#the-bug-it-found). The review then found that the first version of the handler could not have caught several other bugs, and it was rebuilt; see [What the review changed](#what-the-review-changed).

## The bug it found

A **self-transfer of a full balance inflated the holder count**:

```
alice holds 100, sole holder     -> holderCount = 1
alice transfers 100 to herself   -> holderCount = 2   <- nobody new appeared
```

The lifecycle hooks infer transitions from post-transfer balances: `balanceOf(to) == amount` means the recipient came from zero, and `balanceOf(from) == 0` means the sender left. With `from == to` and a full-balance send, the first is true while the second is false, so the two signals fail to cancel and the count rises for a holder who never appeared.

**Why it matters.** The count is what enforces the holder cap, and a private placement's cap is a regulatory limit. Anyone could repeat a free self-transfer until the count reached `maxHolders`, at which point no genuine investor could be admitted.

**Why the other layers missed it.** Nobody writes a unit test for sending tokens to yourself, because it does nothing. Only random sequencing over a small actor pool produced `from == to`, and only because the pool is small enough for the fuzzer to draw the same actor twice.

The fix discards the case at the top of `moduleTransferred`, and two regression tests pin it: [`test_transfer_selfTransferKeepsCountFlat`](../../test/unit/MaxHoldersModule.t.sol#L163) and [`test_transfer_partialSelfTransferKeepsCountFlat`](../../test/unit/MaxHoldersModule.t.sol#L173). `LockupModule` uses the same inference and was checked for the same flaw: it is immune, because a wallet that already has a clock does not get a new one.

---

## The invariants

| Test | Asserts |
| :--- | :------ |
| [`invariant_balancesSumToTotalSupply`](../../test/invariant/Invariants.t.sol#L126) | The balances of the six actors and the outsider sum to `totalSupply`. Only those addresses can ever hold (every other address fails the identity check), so this is the complete sum |
| [`invariant_supplyMatchesMintsMinusBurns`](../../test/invariant/Invariants.t.sol#L138) | `totalSupply` equals the ghost total minted minus the ghost total burned: transfers, freezes, recoveries and identity changes are supply-neutral |
| [`invariant_frozenNeverExceedsBalance`](../../test/invariant/Invariants.t.sol#L151) | `frozenTokens(a) <= balanceOf(a)` for every actor |
| [`invariant_holderCountMatchesReality`](../../test/invariant/Invariants.t.sol#L166) | The module's cached count equals the number of actors holding a positive balance |
| [`invariant_holderCountNeverExceedsCap`](../../test/invariant/Invariants.t.sol#L178) | The count never exceeds `maxHolders` |
| [`invariant_lockupClockMatchesPosition`](../../test/invariant/Invariants.t.sol#L192) | For every actor, a lockup clock exists exactly while the actor holds a balance |
| [`invariant_recoveryKeepsLockupStart`](../../test/invariant/Invariants.t.sol#L205) | No successful recovery left the destination with anything but the earlier of the two wallets' starts, or left the lost wallet with a clock (a counter the handler increments at the moment of each recovery) |
| [`invariant_unverifiedBalanceNeverGrows`](../../test/invariant/Invariants.t.sol#L220) | Every actor that is currently unverified holds at most the balance it held when it stopped being verified |
| [`invariant_dividendsSolvent`](../../test/invariant/Invariants.t.sol#L239) | The distributor's currency balance is at least the sum of what the actors can claim |
| [`invariant_dividendsConserved`](../../test/invariant/Invariants.t.sol#L250) | Total claimed plus total claimable never exceeds total deposited, and falls short of it by at most seven wei |
| [`invariant_blockedHoldersAreNeverPaid`](../../test/invariant/Invariants.t.sol#L259) | No successful claim was made by an actor that was fully frozen or unverified at the time (a counter the handler increments on such a claim) |
| [`invariant_noUnexpectedReverts`](../../test/invariant/Invariants.t.sol#L272) | Every revert the handler caught was one its action may legitimately produce; the failure message names the last action that produced an unexpected one |

Several deserve their reasoning stated.

**Supply conservation is where recovery would show up.** `forcedRecovery` touches balances, freeze state and the registry in one call while bypassing the transfer gate. If its ordering were wrong it would mint or destroy, and the ghost-tracked `minted - burned` is what would catch it.

**The cap is not implied by the gate.** Recovery skips `moduleCheck`, so nothing stops it raising the count on the way past, except that a recovery always empties the lost wallet in the same movement that fills the new one. The invariant asserts the consequence rather than trusting the argument.

**Two invariants are checked at the moment, not at the end.** Whether a recovery kept the right lockup start, and whether a claimant was blocked when paid, cannot be read from the state afterwards: by then the starts have moved and the freeze may have been lifted. The handler checks each at the moment of the successful call and counts violations; the invariant asserts the counter is zero.

**"Verified holders only" is deliberately weaker than it sounds.** It is *not* "no unverified address holds a balance", which is false by design: `removeIdentity` suspends a live position rather than confiscating it, so an unverified wallet keeps what it had. What the gate enforces is that the balance cannot **grow**. The handler records each actor's balance at the moment it stops being verified, after every action, so a removal, a recovery and a KYC expiring during a warp are all captured before the next action can move tokens.

**The dividend conservation bound is one-sided and justified.** Paid plus owed may never exceed what was deposited: that direction would be insolvency, so there is no tolerance on it. The other direction allows seven wei, and the source states why: each account's entitlement is descaled with a floor, losing under one wei per account, and six actors can hold; the deposit remainder carried in `residue` is below one whole unit. Transfers, burns and recoveries move corrections equal and opposite, so they add no further loss. The bound is `actors.length + 1` in the code, not a free constant.

---

## The handler

[`Handler.sol`](../../test/invariant/Handler.sol) exposes fifteen actions. Each counts its attempts and successes, and classifies every revert it catches.

| Action | Notes |
| :--- | :--- |
| [`mint`](../../test/invariant/Handler.sol#L317) / [`burn`](../../test/invariant/Handler.sol#L331) | Issuance up to 1,000,000 tokens and retirement up to the balance, both by amount mode, tracked in ghost totals. The issuer may burn through a freeze and burn zero from an empty wallet |
| [`transfer`](../../test/invariant/Handler.sol#L344) | Any actor to any actor, including itself, by amount mode against the sender's balance |
| [`approve`](../../test/invariant/Handler.sol#L359) / [`transferFrom`](../../test/invariant/Handler.sol#L372) | The spender is any actor or the outsider; half the approvals are unlimited, so an allowance shortfall arises only after a smaller re-approval |
| [`setAddressFrozen`](../../test/invariant/Handler.sol#L394) | Freezing throttled to one draw in four; unfreezing a frozen wallet is not throttled |
| [`freezePartialTokens`](../../test/invariant/Handler.sol#L407) / [`unfreezePartialTokens`](../../test/invariant/Handler.sol#L419) | By amount mode against the free and the frozen portion respectively |
| [`togglePause`](../../test/invariant/Handler.sol#L433) | Entering a pause throttled to one draw in ten; leaving one is not |
| [`forcedRecovery`](../../test/invariant/Handler.sol#L461) | Three draws in four are aimed: the first actor from the seed that holds a balance, recovered into its partner wallet. The rest pick both wallets at random, so the rejections stay exercised |
| [`toggleIdentity`](../../test/invariant/Handler.sol#L500) | Withdrawal throttled to one draw in five; restoration (also of an expired KYC) is not, and re-registers the actor with its original investor id and country |
| [`toggleCountry`](../../test/invariant/Handler.sol#L525) | Blocking the third investor's jurisdiction throttled to one draw in five; unblocking is not |
| [`deposit`](../../test/invariant/Handler.sol#L542) | Income from one unit to a thousand whole units of the 6-decimal currency, tracked in a ghost total |
| [`claim`](../../test/invariant/Handler.sol#L557) | Any actor claims, frozen and unverified ones included. Three draws in four move to the first actor with something to claim, so paid claims are not drowned by empty ones |
| [`warp`](../../test/invariant/Handler.sol#L579) | One hour to thirty days, so the 7-day lockup is crossed in both directions and, occasionally, a KYC attestation expires |

### The actors

Six wallets belong to **three investors, two wallets each**: wallets `2k` and `2k+1` share an investor id, so a forced recovery has a valid destination whenever it picks the partner wallet. The third investor's two wallets are registered in France, the jurisdiction `toggleCountry` blocks, so the country rule applies to real holders mid-run. A seventh address, the **outsider**, is never registered and never holds: it only ever acts as a `transferFrom` spender, to exercise the gate's documented blind spot for spenders ([`test_transferFrom_spenderIsNotChecked`](../../test/unit/SecurityToken.t.sol#L638)).

The pool is fixed rather than fuzzed. With free addresses almost every transfer would find an empty sender and revert, and the fuzzer would spend its budget rediscovering that strangers hold nothing. The small pool is also what surfaced the self-transfer bug: it makes `from == to` a likely draw.

### Amounts by mode

Every amount-taking action first draws one of four modes: **zero**, the **full** balance (or free or frozen portion), **one wei**, or **any** amount up to the maximum. Zero and the full balance are exactly the amounts at which the modules infer holder and clock transitions, and a uniform draw over a large range almost never hits them. The zero-amount holder-count bug (review finding 1) lived at one of those points.

### Revert classification

The suite runs with `fail_on_revert = false`, which is necessary (a locked-up transfer *must* be allowed to revert) and is also how an invariant suite silently tests nothing: if a path reverted for the wrong reason every time, every invariant would still hold.

So each action lists the custom errors it may legitimately revert with. For example, a transfer may hit any of the seven gate errors (identity on either side, freeze on either side, the unfrozen balance, `ComplianceCheckFailed`, `EnforcedPause`), `transferFrom` also `ERC20InsufficientAllowance`, recovery its four own rejections, a claim `NothingToClaim`, `ClaimantFrozen` or `ClaimantNotVerified`. Actions such as `approve`, the freeze controls and the toggles list none. A caught revert whose selector is on the action's list is counted per action and per selector; anything else (a panic, an empty revert, an error the action cannot legitimately produce) increments `unexpectedReverts` and is kept in `lastUnexpected`, and [`invariant_noUnexpectedReverts`](../../test/invariant/Invariants.t.sol#L272) asserts the counter stays at zero.

Two expected selectors are unexpected in context:

- **`ComplianceCheckFailed` on a zero amount.** Modules judge value movements only (review finding 12), so a zero-amount mint, transfer or `transferFrom` can be refused by the token-level checks but never by a module.
- **`RecoveryAcrossInvestors` between two wallets of one investor.** The two partner wallets always share an investor id, removed or not (review finding 3), so this error is only legitimate across investors.

### Throttled toggles

Pause, a full freeze, identity withdrawal and the country block are **absorbing**: once taken, they block most other actions until explicitly undone. As independent actions, the fuzzer would enter a paused or fully unverified state within a few draws and spend the remaining depth watching every balance-moving call revert. The invariants would all hold, over a system that did nothing.

Each is therefore a toggle that enters its blocking state on a fraction of draws (one in ten for the pause, one in four for a full freeze, one in five for the other two) and leaves it on every draw that finds it set. The state stays reachable but short-lived. Recovery's exemption from the pause is still exercised, because recovery draws land inside those stretches.

### The deterministic test

| Test | Asserts |
| :--- | :------ |
| [`test_handlerExercisesEveryAction`](../../test/invariant/Invariants.t.sol#L309) | Driven through a fixed sequence from a known-good state, every one of the fifteen actions succeeds at least once, including a zero amount, a full-balance exit, a `transferFrom` by the unverified outsider, a recovery between partner wallets, the country block and a paid claim. A transfer refused by the lockup is counted once under `ComplianceCheckFailed` as an expected revert, `unexpectedReverts` stays at zero, and the actor withdrawn at the end is tracked as unverified |

This test is what makes a green invariant run mean something: it shows every action can reach the code it is meant to exercise. It caught two defects in the first handler: a `vm.prank` consumed by a state-reading call before reaching the call it was meant to authorise, and a throttle that read an already-bounded parameter and so **never withdrew an identity at all**.

The counters cannot be asserted in `afterInvariant`, which does not observe the state a sequence accumulated. [`afterInvariant`](../../test/invariant/Invariants.t.sol#L283) is kept as a `-vv` readout of what a run exercised: per action, the attempts, the successes and the expected reverts by selector.

---

## What the review changed

The first handler caught every revert with an empty `catch`, so a path that always reverted for the wrong reason was invisible. It drew amounts by range only, gave recovery partner wallets to two of its four investors, and had no `approve`, `transferFrom`, country block, deposit or claim action. The review (commit `6fe5e72`) rebuilt it as described above and changed the invariant set:

- **`invariant_recoveryLeavesEvictedWalletEmpty` was removed.** It recorded the lost wallet's balance right after a full-balance move, so it could not fail. The recovery properties it was meant to cover are now [`invariant_recoveryKeepsLockupStart`](../../test/invariant/Invariants.t.sol#L205), checked at the moment of each recovery, and the snapshot a recovery takes for [`invariant_unverifiedBalanceNeverGrows`](../../test/invariant/Invariants.t.sol#L220) when the lost wallet was verified until then.
- **`invariant_unverifiedHoldersAreConsistent` was replaced** by `invariant_unverifiedBalanceNeverGrows`, which snapshots each actor's balance at the moment it stops being verified. An earlier formulation, "an evicted wallet that is currently unverified holds nothing", was disproved by a correct sequence (evict, re-onboard, receive, withdraw again): it asked about a later state that says nothing about recovery.
- **Six invariants were added**: `lockupClockMatchesPosition`, `recoveryKeepsLockupStart`, `dividendsSolvent`, `dividendsConserved`, `blockedHoldersAreNeverPaid` and `noUnexpectedReverts`.

The commit records that each rebuilt piece was checked by reintroducing a fixed bug: the zero-amount count bug, the recovery re-lock, a claim by a frozen holder and the deleted investor id on removal each make an invariant fail.

---

## Configuration

The suite wires the system by hand rather than inheriting [`Deploy`](../../script/Deploy.s.sol), for two reasons:

- **A 7-day lockup instead of 365.** With a year-long period almost every transfer in a run would be rejected by the same rule, exploring one branch deeply and everything else not at all.
- **A holder cap of 4 instead of 499.** The cap has to be *reachable* within a run for its enforcement branch to be exercised at all.

The distributor is registered before the first mint, so no position predates it or the lockup. Everything else matches the real deployment: the same engine, the same registry, all three rule modules, the same role separation.

```bash
forge test --match-path 'test/invariant/*'                  # default profile: 64 runs x depth 64
FOUNDRY_PROFILE=ci forge test --match-path 'test/invariant/*'   # ci profile: 256 runs x depth 128
FOUNDRY_INVARIANT_RUNS=300 FOUNDRY_INVARIANT_DEPTH=100 \
  forge test --match-path 'test/invariant/*'                # deeper run: 300 x 100
```

The deeper run is the configuration that surfaced the holder-count bug, and the one to use before trusting a change to the modules or the gate.
