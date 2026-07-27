# Modular Compliance (Phase 2)

**Suites:** [`ModularComplianceTest`](../../test/unit/ModularCompliance.t.sol) (26 unit + 2 fuzz)
**Covers:** roadmap item 2.5 · [Guide 3, the compliance engine](../03-architecture.md)

---

> The engine holds the rule set the token consults. It composes modules, answers `canTransfer` as an AND across them, and fans lifecycle events out so stateful rules can record what happened. Two structural properties carry the weight: a rejection by any module must reject the transfer, and a module that cannot actually be driven by this engine must never be registered as if it could.

## Constructor

| Test | Asserts |
| :--- | :------ |
| [`test_constructor_setsState`](../../test/unit/ModularCompliance.t.sol#L51) | The issuer holds `DEFAULT_ADMIN_ROLE`, the module set is empty and no token is bound |
| [`test_constructor_revertsOnZeroIssuer`](../../test/unit/ModularCompliance.t.sol#L57) | A zero issuer reverts `ZeroAddress` |

The engine starts unbound and empty on purpose: it must exist before its modules, because each module binds to an engine address that is immutable at construction. That ordering is what drives the [deployment sequence](./09-deploy.md).

---

## Module admin (2.5)

Adding and removing rules is the ISSUER's power, gated by `DEFAULT_ADMIN_ROLE`. This is the seam that lets the rule set change by governance action rather than by redeploying the token.

| Test | Asserts |
| :--- | :------ |
| [`test_addModule_registers`](../../test/unit/ModularCompliance.t.sol#L66) | The module joins the set, `ModuleAdded` fires, and `modules()` reflects it |
| [`test_addModule_revertsForNonAdmin`](../../test/unit/ModularCompliance.t.sol#L79) | A stranger cannot extend the rule set |
| [`test_addModule_revertsOnZeroAddress`](../../test/unit/ModularCompliance.t.sol#L88) | A zero module address is refused |
| [`test_addModule_revertsOnDuplicate`](../../test/unit/ModularCompliance.t.sol#L94) | Adding the same module twice reverts `ModuleAlreadyAdded`, so a rule cannot be silently applied twice |
| [`test_addModule_revertsForModuleBoundToDifferentEngine`](../../test/unit/ModularCompliance.t.sol#L102) | **Module integrity.** A module whose immutable binding points at another engine reverts `ModuleNotBound` |
| [`test_removeModule_deregisters`](../../test/unit/ModularCompliance.t.sol#L113) | The module leaves the set and `ModuleRemoved` fires, while the other module is untouched |
| [`test_removeModule_revertsForNonAdmin`](../../test/unit/ModularCompliance.t.sol#L127) | Removal is admin-gated: a rule cannot be disabled by anyone else |
| [`test_removeModule_revertsWhenNotRegistered`](../../test/unit/ModularCompliance.t.sol#L137) | Removing an unregistered module reverts `ModuleNotFound` rather than succeeding as a no-op |

**Why the integrity check is the interesting one.** A module's engine binding is immutable, set at construction. If a module bound to engine A were added to engine B, every hook B fired at it would revert on `onlyCompliance`, so the module's state would never update. It would appear in `modules()`, appear active in every listing, and enforce nothing — a rule that silently does not exist. Refusing it at registration converts a silent misconfiguration into a failed transaction at deployment time. The same guard is what makes the deployment script's `addModule` calls double as an assertion that the modules were constructed against the right engine.

---

## Token binding (2.5)

| Test | Asserts |
| :--- | :------ |
| [`test_bindToken_binds`](../../test/unit/ModularCompliance.t.sol#L147) | The token is bound and `TokenBound` fires |
| [`test_bindToken_revertsForNonAdmin`](../../test/unit/ModularCompliance.t.sol#L157) | Binding is admin-gated |
| [`test_bindToken_revertsOnZeroAddress`](../../test/unit/ModularCompliance.t.sol#L166) | A zero token is refused |
| [`test_bindToken_revertsWhenAlreadyBound`](../../test/unit/ModularCompliance.t.sol#L172) | **Binding is one-shot**: rebinding reverts `TokenAlreadyBound`, naming the incumbent |

One-shot binding is what makes the lifecycle hooks trustworthy. The hooks mutate module state (a holder count, a lockup clock), so if the engine could be rebound, a second token could drive the same modules and corrupt the state of the first. The engine accepts hooks from exactly one address, for its whole life.

---

## The check is an AND

| Test | Asserts |
| :--- | :------ |
| [`test_canTransfer_trueWithNoModules`](../../test/unit/ModularCompliance.t.sol#L183) | An empty rule set allows everything: the engine adds no policy of its own |
| [`test_canTransfer_trueWhenAllModulesAllow`](../../test/unit/ModularCompliance.t.sol#L187) | Every module allowing means the engine allows |
| [`test_canTransfer_falseWhenAnyModuleRejects`](../../test/unit/ModularCompliance.t.sol#L192) | The **last** module rejecting rejects the transfer |
| [`test_canTransfer_falseWhenFirstModuleRejects`](../../test/unit/ModularCompliance.t.sol#L198) | The **first** module rejecting rejects the transfer |

The last two exist as a pair deliberately. Testing only one end would leave a short-circuit bug undetected: an implementation that returned the first module's verdict, or that overwrote the running result on each iteration, passes one of these tests and fails the other. Together they pin that a rejection anywhere in the set is decisive regardless of position.

---

## Lifecycle hooks

The hooks are state-mutating and cannot reject. They run *after* balances move, so stateful modules read settled balances to decide what changed.

| Test | Asserts |
| :--- | :------ |
| [`test_transferred_fansOutToEveryModule`](../../test/unit/ModularCompliance.t.sol#L208) | Both modules receive `moduleTransferred` with the same `(from, to, amount)` |
| [`test_created_fansOutToEveryModule`](../../test/unit/ModularCompliance.t.sol#L222) | Both modules receive `moduleCreated` on a mint |
| [`test_destroyed_fansOutToEveryModule`](../../test/unit/ModularCompliance.t.sol#L235) | Both modules receive `moduleDestroyed` on a burn |
| [`test_hooks_noopWithNoModules`](../../test/unit/ModularCompliance.t.sol#L248) | With no modules registered the hooks are harmless no-ops rather than reverting |
| [`test_transferred_revertsForNonToken`](../../test/unit/ModularCompliance.t.sol#L257) | Only the bound token may fire `transferred` |
| [`test_created_revertsForNonToken`](../../test/unit/ModularCompliance.t.sol#L265) | Only the bound token may fire `created` |
| [`test_destroyed_revertsForNonToken`](../../test/unit/ModularCompliance.t.sol#L272) | Only the bound token may fire `destroyed` |
| [`test_hooks_revertBeforeBind`](../../test/unit/ModularCompliance.t.sol#L279) | Before any token is bound, every hook reverts rather than accepting calls from anyone |

The `onlyToken` gate is the reason module state can be trusted. A holder count or a lockup clock is only meaningful if the sole thing that can move it is a real balance change on the real token. Without the gate, anyone could call `transferred` with fabricated arguments and desynchronise the count from reality — which is precisely the property [`testFuzz_countMatchesReality`](../../test/unit/MaxHoldersModule.t.sol#L290) asserts on the other side.

`test_hooks_revertBeforeBind` closes the window where `_token` is still zero: without it, an unbound engine would compare the caller against `address(0)` and reject everyone, but the test pins that behaviour rather than leaving it to inference.

---

## Fuzz

| Test | Property |
| :--- | :------- |
| [`testFuzz_canTransfer_requiresEveryModule`](../../test/unit/ModularCompliance.t.sol#L291) | For any combination of module verdicts, the engine's answer is the AND of them |
| [`testFuzz_transferred_fansOut`](../../test/unit/ModularCompliance.t.sol#L298) | For any `(from, to, amount)`, every registered module receives exactly those arguments |

The first is the fuzzed form of the two point tests above: rather than checking the first and last positions, it drives every combination of allow/reject across the set and asserts the composition is a strict AND.
