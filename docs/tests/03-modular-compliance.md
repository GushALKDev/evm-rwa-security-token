# Modular Compliance (Phase 2)

**Suites:** [`ModularComplianceTest`](../../test/unit/ModularCompliance.t.sol) (36 unit + 2 fuzz)
**Covers:** roadmap item 2.5 · [Guide 3, the compliance engine](../03-architecture.md)

---

> The engine holds the rule set the token consults. It composes modules, answers `canTransfer` as an AND across them, and fans lifecycle events out so stateful rules can record what happened. Three structural properties carry the weight: a rejection by any module must reject the transfer, a module that cannot actually be driven by this engine must never be registered as if it could, and a stateful module must never be attached where it cannot have seen every balance movement.

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
| [`test_addModule_registers`](../../test/unit/ModularCompliance.t.sol#L66) | `ModuleAdded` fires, `isModuleRegistered` is true and `modules()` lists exactly that module |
| [`test_addModule_revertsForNonAdmin`](../../test/unit/ModularCompliance.t.sol#L79) | A stranger cannot extend the rule set (`AccessControlUnauthorizedAccount` with the admin role) |
| [`test_addModule_revertsOnZeroAddress`](../../test/unit/ModularCompliance.t.sol#L88) | A zero module address reverts `ZeroAddress` |
| [`test_addModule_revertsOnDuplicate`](../../test/unit/ModularCompliance.t.sol#L94) | Adding the same module twice reverts `ModuleAlreadyAdded`, so a rule cannot be applied twice |
| [`test_addModule_revertsForModuleBoundToDifferentEngine`](../../test/unit/ModularCompliance.t.sol#L102) | **Module integrity.** A module whose immutable binding points at another engine reverts `ModuleNotBound` |
| [`test_addModule_capsTheModuleCount`](../../test/unit/ModularCompliance.t.sol#L195) | `MAX_MODULES` is 25; twenty-five modules register, the twenty-sixth reverts `ModuleLimitReached(25)`, and after one removal it registers. Pins hardening entry 3 of the review notes (the module cap); removing the cap makes it fail |
| [`test_removeModule_deregisters`](../../test/unit/ModularCompliance.t.sol#L113) | The module leaves the set and `ModuleRemoved` fires, while the other module stays registered |
| [`test_removeModule_revertsForNonAdmin`](../../test/unit/ModularCompliance.t.sol#L214) | Removal is admin-gated: a rule cannot be disabled by anyone else |
| [`test_removeModule_revertsWhenNotRegistered`](../../test/unit/ModularCompliance.t.sol#L224) | Removing an unregistered module reverts `ModuleNotFound` rather than succeeding as a no-op |

**Why the integrity check is the interesting one.** A module's engine binding is immutable, set at construction. If a module bound to engine A were added to engine B, every hook B fired at it would revert on `onlyCompliance`, so the module's state would never update. It would appear in `modules()`, appear active in every listing, and enforce nothing. Refusing it at registration converts a silent misconfiguration into a failed transaction at deployment time. The same guard is what makes the deployment script's `addModule` calls double as an assertion that the modules were constructed against the right engine.

The cap bounds the loops every transfer runs through the module set (the check and the three hooks), matching the T-REX limit.

---

## Attachment: the plug-and-play shape

Review finding 6 showed that `addModule` and `removeModule` reconciled nothing with existing balances. The engine now follows the T-REX `isPlugAndPlay` / `canComplianceBind` shape: registration calls `bindCompliance` on the module, removal calls `unbindCompliance`, and a module that is not plug and play refuses a second attach. These tests use [`MockModule`](../../test/helpers/MockModule.sol) (plug and play) and `StatefulMockModule` (not plug and play). The same guards against the real modules are in the [module suites](./04-lockup-module.md#attachment) and in [Regressions](./14-regressions.md#6-stateful-modules-could-be-attached-where-they-could-not-keep-up).

| Test | Asserts |
| :--- | :------ |
| [`test_addAndRemoveModule_bindAndUnbindTheModule`](../../test/unit/ModularCompliance.t.sol#L128) | `addModule` makes the module emit `ComplianceBound(engine)` and report `isComplianceBound(engine)`; `removeModule` makes it emit `ComplianceUnbound(engine)` and report false |
| [`test_addModule_plugAndPlayModuleCanReturn`](../../test/unit/ModularCompliance.t.sol#L143) | A plug-and-play module added, removed and added again is registered |
| [`test_addModule_revertsWhenStatefulModuleReturns`](../../test/unit/ModularCompliance.t.sol#L153) | A stateful module added and removed reverts `ModuleCannotBind` on its second attach: it missed every movement made while it was out |
| [`test_canComplianceBind_falseForAnotherEngine`](../../test/unit/ModularCompliance.t.sol#L164) | A module answers `canComplianceBind` true only for its own engine, and `isComplianceBound` is false for any other address |
| [`test_bindCompliance_eventNamesTheBoundEngine`](../../test/unit/ModularCompliance.t.sol#L171) | Called by the engine with a different address as argument, `bindCompliance` and `unbindCompliance` emit events naming the bound engine, not the argument. Written with the fix for the defect listed under "Introduced and fixed during the review" |
| [`test_bindAndUnbindCompliance_revertForNonEngine`](../../test/unit/ModularCompliance.t.sol#L184) | A stranger calling `bindCompliance` or `unbindCompliance` reverts `OnlyCompliance(stranger, engine)` |

---

## Token binding (2.5)

| Test | Asserts |
| :--- | :------ |
| [`test_bindToken_binds`](../../test/unit/ModularCompliance.t.sol#L234) | The token is bound and `TokenBound` fires |
| [`test_bindToken_revertsForNonAdmin`](../../test/unit/ModularCompliance.t.sol#L281) | Binding is admin-gated |
| [`test_bindToken_revertsOnZeroAddress`](../../test/unit/ModularCompliance.t.sol#L290) | A zero token reverts `ZeroAddress` |
| [`test_bindToken_revertsWhenAlreadyBound`](../../test/unit/ModularCompliance.t.sol#L296) | **Binding is one-shot**: rebinding reverts `TokenAlreadyBound`, naming the incumbent |
| [`test_moduleToken_matchingOrZeroIsAccepted`](../../test/unit/ModularCompliance.t.sol#L245) | A module reading the bound token (added before the bind) and a module reading no token (added after it) are both accepted |
| [`test_addModule_revertsForModuleReadingAnotherToken`](../../test/unit/ModularCompliance.t.sol#L256) | With the engine bound first, a module whose `token()` is a different address reverts `ModuleTokenMismatch(module, moduleToken, boundToken)` |
| [`test_bindToken_revertsWhenARegisteredModuleReadsAnotherToken`](../../test/unit/ModularCompliance.t.sol#L269) | With the module registered first, binding the engine to a token that module does not read reverts `ModuleTokenMismatch` |

One-shot binding is what makes the lifecycle hooks trustworthy. The hooks mutate module state (a holder count, a lockup clock), so if the engine could be rebound, a second token could drive the same modules and corrupt the state of the first. The engine accepts hooks from exactly one address, for its whole life.

The last three are the unit form of review finding 7: a stateful module built against another token was accepted and then counted that token's balances. The check runs in both orders (module then bind, bind then module), and a module that reads no token at all is left alone. The deployed-wiring regressions are under [finding 7](./14-regressions.md#7-a-module-could-read-a-different-token-than-the-engines).

---

## The check is an AND

| Test | Asserts |
| :--- | :------ |
| [`test_canTransfer_trueWithNoModules`](../../test/unit/ModularCompliance.t.sol#L307) | An empty rule set allows everything: the engine adds no policy of its own |
| [`test_canTransfer_trueWhenAllModulesAllow`](../../test/unit/ModularCompliance.t.sol#L311) | Every module allowing means the engine allows |
| [`test_canTransfer_falseWhenAnyModuleRejects`](../../test/unit/ModularCompliance.t.sol#L316) | The **last** module rejecting rejects the transfer |
| [`test_canTransfer_falseWhenFirstModuleRejects`](../../test/unit/ModularCompliance.t.sol#L322) | The **first** module rejecting rejects the transfer |

The last two exist as a pair deliberately. Testing only one end would leave a short-circuit bug undetected: an implementation that returned the first module's verdict, or that overwrote the running result on each iteration, passes one of these tests and fails the other.

---

## Lifecycle hooks

The hooks are state-mutating and cannot reject. They run *after* balances move, so stateful modules read settled balances to decide what changed.

| Test | Asserts |
| :--- | :------ |
| [`test_transferred_fansOutToEveryModule`](../../test/unit/ModularCompliance.t.sol#L332) | Both modules receive `moduleTransferred` once, with the same `(from, to, amount)` |
| [`test_created_fansOutToEveryModule`](../../test/unit/ModularCompliance.t.sol#L349) | Both modules receive `moduleCreated` once on a mint, with the recipient and amount |
| [`test_destroyed_fansOutToEveryModule`](../../test/unit/ModularCompliance.t.sol#L362) | Both modules receive `moduleDestroyed` once on a burn, with the holder and amount |
| [`test_hooks_noopWithNoModules`](../../test/unit/ModularCompliance.t.sol#L375) | With no modules registered the three hooks complete without reverting |
| [`test_transferred_revertsForNonToken`](../../test/unit/ModularCompliance.t.sol#L384) | Only the bound token may fire `transferred` (`OnlyToken(caller, token)`) |
| [`test_created_revertsForNonToken`](../../test/unit/ModularCompliance.t.sol#L392) | Only the bound token may fire `created` |
| [`test_destroyed_revertsForNonToken`](../../test/unit/ModularCompliance.t.sol#L399) | Only the bound token may fire `destroyed` |
| [`test_hooks_revertBeforeBind`](../../test/unit/ModularCompliance.t.sol#L406) | Before any token is bound, all three hooks revert `OnlyToken(caller, address(0))` and no module hook counter moves |

The `onlyToken` gate is the reason module state can be trusted. A holder count or a lockup clock is only meaningful if the sole thing that can move it is a real balance change on the real token. Without the gate, anyone could call `transferred` with fabricated arguments and desynchronise the count from reality, which is the property [`testFuzz_countMatchesReality`](../../test/unit/MaxHoldersModule.t.sol#L351) asserts on the other side.

`test_hooks_revertBeforeBind` closes the window where `_token` is still zero, pinning the behaviour rather than leaving it to inference.

---

## Fuzz

| Test | Asserts |
| :--- | :------ |
| [`testFuzz_canTransfer_requiresEveryModule`](../../test/unit/ModularCompliance.t.sol#L425) | For any pair of verdicts from the two modules, the engine's answer is their AND |
| [`testFuzz_transferred_fansOut`](../../test/unit/ModularCompliance.t.sol#L432) | For any `(from, to, amount)`, both registered modules receive exactly those arguments, once |

The first is the fuzzed form of the two point tests above: with two modules the four verdict combinations are the whole domain, and it asserts the composition is a strict AND.
