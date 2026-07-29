# Gaps & Roadmap

**Section:** [Testing Documentation](./README.md)

---

> What the suite does not cover, stated plainly so the gaps are not mistaken for oversights. Each entry says whether it is a **pending deliverable** (a phase will close it), an **accepted limitation** (it will not be closed, and why), or a **known issue** (it should be closed and is not yet scheduled).

## Pending deliverables

### Deployment handover (no phase assigned)

`_deploy` requires the executing account to be the issuer, since the wiring calls are admin-gated. Passing a different `ISSUER` grants that address admin and then reverts on the first wiring call. A production deployment wants deploy-then-handover: the deployer wires everything, then transfers `DEFAULT_ADMIN_ROLE` to the real issuer. Currently documented in the script's NatSpec and untested, because the behaviour it would test does not exist yet.

### The dividend distributor is outside the handler suite (no phase assigned)

The invariant handler drives the system `Deploy` produces, and the distributor is deliberately not part of that deployment (see below). Its solvency and conservation properties are therefore fuzzed at 20,000 runs and walked end to end in the [scenario suite](./13-dividend-distributor.md#integration), but never interleaved with pause, freeze, `removeIdentity` and forced recovery in an arbitrary order the way the token's properties are.

This is the one gap in the dividend unit worth naming, because the suite it is missing from is precisely the one that found the holder-count bug. Closing it means adding `deposit` and `claim` actions to the handler and asserting `Σ claimable + Σ withdrawn <= Σ deposited` as a stateful invariant. The deposit action would need the same throttling discipline the absorbing actions already use, or the accumulator would be perturbed on nearly every call.

---

## Closed

### The handler-based invariant suite (roadmap 6.2 / 6.3) — closed

Delivered: seven invariants driven by a bounded handler across arbitrary sequences. See [Invariant Suite](./11-invariants.md).

It closed the gap by finding a real bug rather than merely confirming the existing tests: a self-transfer of a full balance inflated `holderCount`, which would have let anyone exhaust the holder cap and lock genuine investors out of the placement. Every other layer missed it, because nobody writes a unit test for sending tokens to themselves.

What remains true is the distinction the map still draws: the properties now hold across interleavings of every state-mutating entry point, at 30,000 calls per invariant in the high-effort configuration.

---

## Accepted limitations

### `script/Deploy.s.sol` is at ~61%

The tests call `_deploy` directly to avoid opening a broadcast context, leaving `run()` and `_logDeployment` uncovered. Both exist only to wrap `_deploy` in `startBroadcast`/`stopBroadcast` and print an address book. Driving `console2.log` to raise a percentage would assert nothing about the deployment, so the number is left where it is and explained here instead.

### The dividend distributor is not in `Deploy.s.sol`

Phase 8 is a stretch unit, and wiring it into the deployment script would change the documented deployment and the address book the [Deployment tests](./09-deploy.md) assert against. The [scenario suite](./13-dividend-distributor.md#integration) registers it with `addModule` after `_deploy` returns, which exercises the same wiring and additionally demonstrates that the capability can be added to an already-live system. A deployment that intends to pay income would add it to the script and to `DeployTest`.

### No upgrade, proxy or factory tests

The system deliberately has none. Contracts are immutable and deployed once; the rule set changes by adding and removing modules, not by upgrading code. The reasoning is in [Guide 4](../04-tradeoffs.md), and the migration path a production build would take is in [Guide 6](../06-improvements.md).

### No multi-token or shared-identity tests

One registry serves one token here. ERC-3643's ONCHAINID makes an identity reusable across tokens; this project collapses that into a flat registry with an `investorId`, so cross-token identity reuse is out of scope by construction.

### The off-chain half is untestable on-chain

Whether a KYC attestation reflects reality is not something the chain can verify. `isVerified` means "someone attested this and it has not expired", never "this investor is genuinely KYC-clean". `kycExpiry` is what keeps the projection honest over time, and the tests assert the expiry mechanics rather than the underlying fact. See [Guide 4 §4.3](../04-tradeoffs.md#43-on-chain-verification-is-a-projection).

### Gas is not asserted

No test pins a gas figure. The storage layout is chosen so the hot path (`isVerified` on every transfer) is one `SLOAD`, and that packing is verified with `forge inspect storageLayout` rather than by asserting a gas number that would churn with every compiler release.

---

## Residual risks the tests deliberately do not defend against

These are **accepted design positions**, not gaps. They are listed here because a reader scanning for coverage should not mistake a deliberate decision for a missing test.

| Risk | Position |
| :--- | :------- |
| **Issuer authority is centralised** | The issuer holds `DEFAULT_ADMIN_ROLE` and can self-grant `AGENT` and `CUSTODIAN`. Faithful to ERC-3643 and to the regulatory reality it encodes. Mitigation path (multisig + timelock) is governance infrastructure, orthogonal to the architecture |
| **A custodian key plus an agent key can collude** | An agent can link an attacker-controlled wallet to a victim's `investorId`; a custodian can then recover into it. Neither key alone suffices. Contained by role separation and by the audit trail, not prevented |
| **Recovery bypasses the rule set** | Deliberate, and tested as such ([`test_forcedRecovery_succeedsWhenComplianceRejects`](../../test/unit/SecurityToken.t.sol#L646)). The consequence is that modules offer no secondary containment against a compromised custodian key: the `investorId` check and the event trail are the containment |
| **A withdrawn identity leaves a suspended balance** | An unverified address can still *hold*, just not move. This is why the coverage map phrases the property as "no unverified address can increase its balance". Confiscation is the issuer's burn or the custodian's recovery, both deliberate acts |

Full treatment of each in [Guide 4: Trade-offs](../04-tradeoffs.md) and the [README threat model](../../README.md#threat-model).

---

## Summary

| Item | Kind | Closes in |
| :--- | :--- | :-------- |
| Handler-based invariant suite | **Closed** | Phase 6.2 / 6.3 (found a live bug) |
| Deployment handover | Pending | Unscheduled |
| Distributor in the handler suite | Pending | Unscheduled |
| Distributor in `Deploy.s.sol` | Accepted | Only if the note pays income |
| `Deploy.s.sol` coverage | Accepted | Never |
| Upgrades, proxies, factory | Accepted | Never (see Guide 6) |
| Multi-token identity | Accepted | Never (scope) |
| Off-chain KYC truth | Accepted | Not on-chain |
| Gas assertions | Accepted | Never |
