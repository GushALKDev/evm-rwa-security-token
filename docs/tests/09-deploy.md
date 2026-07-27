# Deployment (Phase 5)

**Suites:** [`DeployTest`](../../test/unit/Deploy.t.sol) (15 integration)
**Covers:** roadmap items 5.1 to 5.3 · [Guide 3, deployment order](../03-architecture.md#7-deployment-order-and-the-binding-graph)

---

> [`Deploy.s.sol`](../../script/Deploy.s.sol) already asserts its own wiring before reporting success, so these tests deliberately do **not** re-assert the same equalities — that would only test the assertions. They test the behaviour those assertions stand in for, because a missing role or an unbound engine does not revert at deployment. It reverts on the first transfer in production, months later, and that is the failure this suite exists to prevent.
>
> The suite inherits `Deploy` and calls `_deploy` directly, so it runs against the same construction order a real deployment performs. A fixture that rebuilt the wiring by hand could drift from the script silently.

## The wiring graph (5.1)

| Test | Asserts |
| :--- | :------ |
| [`test_wiring_tokenIsBoundToEngine`](../../test/unit/Deploy.t.sol#L71) | The engine is bound to the token, without which every mint would revert on the lifecycle hook |
| [`test_wiring_allThreeModulesRegistered`](../../test/unit/Deploy.t.sol#L75) | All three rule modules are registered and enumerable |
| [`test_wiring_tokenHoldsAgentOnRegistry`](../../test/unit/Deploy.t.sol#L84) | **The token itself holds `AGENT_ROLE` on the registry** |
| [`test_wiring_operatorRolesGranted`](../../test/unit/Deploy.t.sol#L88) | Agent, custodian and issuer hold the roles the running system needs |
| [`test_wiring_agentCannotRecover`](../../test/unit/Deploy.t.sol#L97) | **The AGENT/CUSTODIAN split survived deployment**: the compliance desk cannot seize a position |

The registry grant is the least visible step in the whole deployment. `forcedRecovery` evicts the lost wallet by calling `removeIdentity`, which is agent-gated, so the *contract* must hold `AGENT_ROLE` — a role held by code rather than by a person. Omit it and everything looks correct: the token deploys, transfers work, freezes work, and recovery fails at the last line of the one operation you need during an incident.

`test_wiring_agentCannotRecover` is a negative test about the deployment rather than the contract. `SecurityToken` enforces the role split by construction; what this asserts is that the *script* did not quietly grant both roles to the same account, which is exactly the shortcut a deployment under time pressure takes.

---

## The system is live (5.3)

Wiring assertions prove the graph is connected. These prove it carries traffic.

| Test | Asserts |
| :--- | :------ |
| [`test_live_mintReachesComplianceModules`](../../test/unit/Deploy.t.sol#L116) | A mint reaches the engine, which fans out to the modules, and the holder count actually moves |
| [`test_live_transferToUnverifiedReverts`](../../test/unit/Deploy.t.sol#L126) | The gate is wired to the real registry: an unverified recipient is refused |
| [`test_live_lockupBlocksEarlyTransfer`](../../test/unit/Deploy.t.sol#L137) | The lockup module is not merely registered but enforcing, at the deployed 365-day period |
| [`test_live_transferSucceedsAfterLockup`](../../test/unit/Deploy.t.sol#L149) | And clears once the period elapses, proving the block above came from the lockup clock rather than some other rule |
| [`test_live_countryRestrictionBlocksRecipient`](../../test/unit/Deploy.t.sol#L164) | The country module reads the registry the script wired into it |
| [`test_live_forcedRecoveryEvictsLostWallet`](../../test/unit/Deploy.t.sol#L184) | Recovery completes end to end, which only succeeds because the registry grant above is real |

The pairing of `lockupBlocksEarlyTransfer` with `transferSucceedsAfterLockup` is deliberate. A blocked transfer alone proves only that *something* rejected it — a mis-wired module rejecting everything would pass that test just as happily. Showing the same transfer succeed after the exact configured period is what identifies the lockup as the cause.

`test_live_forcedRecoveryEvictsLostWallet` is the end-to-end proof of the registry grant: the eviction is an inter-contract call that only the granted role permits, so the test fails loudly if that step were dropped from the script.

---

## The document anchor (5.2)

| Test | Asserts |
| :--- | :------ |
| [`test_anchor_matchesFileOnDisk`](../../test/unit/Deploy.t.sol#L205) | The anchored hash equals `keccak256` of the terms file read from disk at test time |
| [`test_anchor_storesUriAndTimestamp`](../../test/unit/Deploy.t.sol#L212) | The published URI and the anchoring timestamp are recorded |
| [`test_anchor_nameIsReadableLabel`](../../test/unit/Deploy.t.sol#L220) | The document is anchored under `bytes32("TERMS")`, a decodable label rather than an opaque hash |
| [`test_anchor_detectsDriftedDocument`](../../test/unit/Deploy.t.sol#L229) | **The failure the anchor exists to catch**: altered content produces a hash that no longer matches the anchor |

The script computes the hash with `vm.readFile` rather than accepting it as a parameter or a constant, and these tests recompute it independently. A hardcoded hash would drift silently the first time anyone edits the terms document — the anchor would still be *an* anchor, just to a version that no longer exists anywhere.

`test_anchor_detectsDriftedDocument` simulates an amendment by hashing altered content rather than writing to the real file, so it demonstrates the detection without leaving the repository in a modified state.

---

## What this suite does not cover

`run()` and the address logging are uncovered, which is why `script/Deploy.s.sol` sits at roughly 61% rather than 100%. The tests call `_deploy` directly to avoid opening a broadcast context, so the outer wrapper — which does nothing but wrap `_deploy` in `startBroadcast`/`stopBroadcast` and print addresses — is never entered. Driving `console2.log` calls to raise a coverage number would not establish anything about the deployment.

One known limitation is documented in the script's NatSpec rather than tested: `_deploy` requires the executing account to be the issuer, because the wiring calls are admin-gated. Deploying on behalf of a different issuer would grant that issuer admin and then revert on the first wiring call. A production deployment needs a deploy-then-handover step, which is listed in [Gaps & Roadmap](./12-gaps-and-roadmap.md).
