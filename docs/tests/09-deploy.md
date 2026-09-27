# Deployment (Phase 5)

**Suites:** [`DeployTest`](../../test/unit/Deploy.t.sol) (19 integration)
**Covers:** roadmap items 5.1 to 5.3 · [Guide 3, deployment order](../03-architecture.md#7-deployment-order-and-the-binding-graph)

---

> [`Deploy.s.sol`](../../script/Deploy.s.sol) already asserts its own wiring in `_verify` before reporting success, so these tests deliberately do **not** re-assert every one of the same equalities: that would only test the assertions. They test the behaviour those assertions stand in for, because a missing role or an unbound engine does not revert at deployment. It reverts on the first transfer after launch, and that is the failure this suite exists to catch.
>
> The suite inherits `Deploy` and calls `_deploy` directly, so it runs against the same construction order a real deployment performs. A fixture that rebuilt the wiring by hand could drift from the script silently. Two tests go through `run()` as well, with the environment controlled.

## The wiring graph (5.1)

| Test | Asserts |
| :--- | :------ |
| [`test_wiring_tokenIsBoundToEngine`](../../test/unit/Deploy.t.sol#L74) | The engine is bound to the token, without which every mint would revert on the lifecycle hook |
| [`test_wiring_allThreeModulesRegistered`](../../test/unit/Deploy.t.sol#L78) | Exactly three modules are registered: the holder cap, the country restriction and the lockup |
| [`test_wiring_tokenHoldsAgentOnRegistry`](../../test/unit/Deploy.t.sol#L87) | **The token itself holds `AGENT_ROLE` on the registry** |
| [`test_wiring_operatorRolesGranted`](../../test/unit/Deploy.t.sol#L91) | The agent holds `AGENT_ROLE` on the token and the registry, the custodian `CUSTODIAN_ROLE`, and the issuer `DEFAULT_ADMIN_ROLE` on the token |
| [`test_wiring_agentCannotRecover`](../../test/unit/Deploy.t.sol#L100) | **The AGENT/CUSTODIAN split survived deployment**: with two wallets of the same investor, so that only the role can refuse it, the agent's recovery reverts with the `AccessControlUnauthorizedAccount` selector |

The registry grant is the least visible step in the whole deployment. `forcedRecovery` evicts the lost wallet by calling `removeIdentity`, which is agent-gated, so the *contract* must hold `AGENT_ROLE`: a role held by code rather than by a person. Omit it and everything looks correct until recovery fails at the last line of the one operation needed during an incident.

`test_wiring_agentCannotRecover` is a negative test about the deployment rather than the contract. `SecurityToken` enforces the role split by construction; what this asserts is that the *script* did not grant both roles to the same account.

---

## The system is live (5.3)

Wiring assertions show the graph is connected. These show it carries traffic.

| Test | Asserts |
| :--- | :------ |
| [`test_live_mintReachesComplianceModules`](../../test/unit/Deploy.t.sol#L119) | A mint credits the holder and the holder count moves to 1, so the engine reached the modules |
| [`test_live_transferToUnverifiedReverts`](../../test/unit/Deploy.t.sol#L129) | The gate is wired to the real registry: an unverified recipient reverts `RecipientNotVerified` |
| [`test_live_lockupBlocksEarlyTransfer`](../../test/unit/Deploy.t.sol#L140) | A freshly minted position cannot move: the transfer reverts `ComplianceCheckFailed` |
| [`test_live_transferSucceedsAfterLockup`](../../test/unit/Deploy.t.sol#L152) | One second after the deployed 365-day period, the same transfer settles and the holder count moves to 2 |
| [`test_live_countryRestrictionBlocksRecipient`](../../test/unit/Deploy.t.sol#L167) | After the lockup, blocking the recipient's country makes the transfer revert `ComplianceCheckFailed`: the country module reads the registry the script wired into it |
| [`test_live_forcedRecoveryEvictsLostWallet`](../../test/unit/Deploy.t.sol#L187) | Recovery of a freshly minted position moves the whole balance, leaves the lost wallet unverified and supply unchanged, which only succeeds because the registry grant above is real |

The pairing of `lockupBlocksEarlyTransfer` with `transferSucceedsAfterLockup` is deliberate. A blocked transfer alone shows only that *something* rejected it: a mis-wired module rejecting everything would pass that test just as well. Showing the same transfer succeed after the configured period is what identifies the lockup as the cause. Both match the `ComplianceCheckFailed` selector with `expectPartialRevert`.

---

## `run()` end to end

| Test | Asserts |
| :--- | :------ |
| [`test_run_defaultsEveryRoleToTheBroadcaster`](../../test/unit/Deploy.t.sol#L211) | With every operator variable reported unset (a harness overrides `_envAddress`), `run()` binds the token, registers three modules, grants the token `AGENT_ROLE` on the registry, gives the broadcasting account (`tx.origin`) the admin, agent and custodian roles, and anchors the pinned terms hash |
| [`test_run_readsOperatorsFromTheEnvironment`](../../test/unit/Deploy.t.sol#L229) | With `RWA_ISSUER`, `RWA_AGENT` and `RWA_CUSTODIAN` set, the agent and custodian roles land on the given accounts (the agent also on the registry and the holder-cap module), the issuer is the broadcaster, and the broadcaster holds neither the agent nor the custodian role |

Both are regression tests for review finding 16: the role defaults used to read `msg.sender`, while a bare `vm.startBroadcast()` signs as `tx.origin`, so a `run()` called from a contract gave the roles to an account that never sent the wiring calls. The first test does not depend on the runner's environment: the harness returns the fallback for every variable, so an exported `RWA_AGENT` on a developer machine cannot change the result. The second sets all three variables itself for the same reason.

---

## The document anchor (5.2)

| Test | Asserts |
| :--- | :------ |
| [`test_anchor_matchesFileOnDisk`](../../test/unit/Deploy.t.sol#L251) | The anchored hash equals `keccak256` of the terms file read from disk at test time, and the hash the deployment returned |
| [`test_anchor_storesUriAndTimestamp`](../../test/unit/Deploy.t.sol#L258) | The published URI and the anchoring timestamp are recorded |
| [`test_anchor_nameIsReadableLabel`](../../test/unit/Deploy.t.sol#L266) | Exactly one document is anchored, under `bytes32("TERMS")`, a decodable label rather than an opaque hash |
| [`test_anchor_termsFileMatchesPinnedHash`](../../test/unit/Deploy.t.sol#L275) | The file on disk, the script's `TERMS_HASH` and the deployed hash all equal a hash pinned independently in the test. Regression test for review finding 14, which moved both pins to the corrected terms |
| [`test_deploy_revertsWhenTermsDrift`](../../test/unit/Deploy.t.sol#L283) | **A drifted terms document fails the deployment**: a harness that appends a clause to the file's content makes `_deploy` revert `TermsHashMismatch(pinned, drifted)`. Regression test for review findings 11 and 14 |
| [`test_anchor_detectsDriftedDocument`](../../test/unit/Deploy.t.sol#L294) | After deployment, altered content hashes to something other than the anchor, which is the comparison a holder performs |

Review finding 11 was that the deployment hashed whatever the terms file contained and compared the anchor with the same file, so an edited document was anchored instead of rejected. The script and this suite now pin the hash separately; amending the terms is a deliberate change of the file, the script constant and the test constant together. Finding 14 was such an amendment: the terms described an EU allowlist while the code enforces a blocklist, and correcting the document moved both pins.

The drift tests never write to the real file: the harness overrides `_readTerms`, and the post-deployment check hashes altered content in memory.

---

## Coverage of the script

`forge coverage --report summary` reports `script/Deploy.s.sol` at 61/61 lines, 62/62 statements and 6/6 functions, and 15/29 (51.72%) branches. The 14 untaken branches are the failure sides of the `require` checks in `_verify`: each one would need a deployment that is mis-wired in exactly that step, which `_deploy` cannot produce.

One limitation is documented in the script's NatSpec rather than tested: `_deploy` requires the executing account to be the issuer, because the wiring calls are admin-gated. Deploying on behalf of a different issuer would grant that issuer admin and then revert on the first wiring call. A deploy-then-handover step is listed in [Gaps & Roadmap](./12-gaps-and-roadmap.md#deployment-handover).
