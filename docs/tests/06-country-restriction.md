# Country Restriction Module (Phase 2)

**Suites:** [`CountryRestrictionModuleTest`](../../test/unit/CountryRestrictionModule.t.sol) (17 unit + 2 fuzz)
**Covers:** roadmap item 2.3 · [Guide 3, the pluggable seam](../03-architecture.md)

---

> A jurisdiction blocklist, and the only stateless rule in the set: it holds no clocks or counters, just a mapping of ISO 3166-1 numeric codes to a boolean. The tests are correspondingly short, and the interesting ones are all about a single design decision: the rule looks at the **recipient's** jurisdiction and never the sender's.

The suite runs against a real [`IdentityRegistry`](../../src/identity/IdentityRegistry.sol), with one investor in Spain (724) and one in France (250), so the country codes the module reads come from the same place they do in production.

## Constructor

| Test | Asserts |
| :--- | :------ |
| [`test_constructor_setsState`](../../test/unit/CountryRestrictionModule.t.sol#L66) | Engine, registry, name and both roles are set |
| [`test_constructor_revertsOnZeroRegistry`](../../test/unit/CountryRestrictionModule.t.sol#L74) | A zero registry reverts `ZeroAddress`: country codes come from there, so the rule cannot function without it |
| [`test_constructor_revertsOnZeroCompliance`](../../test/unit/CountryRestrictionModule.t.sol#L79) | A zero engine reverts with the `OnlyCompliance` selector raised by the `AbstractComplianceModule` constructor |

---

## Attachment

| Test | Asserts |
| :--- | :------ |
| [`test_attachment_plugAndPlay`](../../test/unit/CountryRestrictionModule.t.sol#L47) | The module is plug and play and reads no token (`token()` is zero); after a bind and an unbind, `canComplianceBind` is still true for its engine |

A stateless rule has nothing to miss while it is detached, so unlike the lockup and the holder cap it may be removed and added back. The same property against the deployed wiring is [`test_addModule_statelessModuleCanBeReattached`](../../test/scenario/Regressions.t.sol#L461).

---

## Enforcement, and why it is recipient-side

| Test | Asserts |
| :--- | :------ |
| [`test_moduleCheck_allowsUnrestrictedCountry`](../../test/unit/CountryRestrictionModule.t.sol#L88) | With nothing blocked, transfers pass |
| [`test_moduleCheck_blocksRestrictedRecipient`](../../test/unit/CountryRestrictionModule.t.sol#L92) | A recipient in a blocked jurisdiction is refused |
| [`test_moduleCheck_ignoresSenderCountry`](../../test/unit/CountryRestrictionModule.t.sol#L102) | **The decision.** With the sender's own country blocked, they may still send; a blocked recipient still may not receive. Both directions asserted in one test |
| [`test_restrictionDoesNotAffectExistingHolders`](../../test/unit/CountryRestrictionModule.t.sol#L143) | With France blocked, the French holder may still send to a Spanish one: closing a jurisdiction does not trap the holders already there |
| [`test_moduleCheck_allowsBurn`](../../test/unit/CountryRestrictionModule.t.sol#L111) | A burn has no recipient to place in a jurisdiction, so the rule allows it even for a holder in a blocked country |
| [`test_moduleCheck_unrestrictingRestoresTransfers`](../../test/unit/CountryRestrictionModule.t.sol#L131) | Reopening a jurisdiction restores transfers immediately: the measure is reversible |
| [`test_moduleCheck_unregisteredRecipientReadsAsCountryZero`](../../test/unit/CountryRestrictionModule.t.sol#L121) | An unregistered wallet reads as country `0`, which is unrestricted by default; blocking `0` explicitly does block it |
| [`test_moduleCheck_zeroAmountPassesForBlockedRecipient`](../../test/unit/CountryRestrictionModule.t.sol#L59) | For a recipient in a blocked country, one wei is refused and a zero amount is allowed: a zero amount places nothing with the recipient |

**Why the sender is ignored.** A distribution restriction governs who the instrument may be *placed with*, not who may exit. Blocking the sender's country too would mean that closing a jurisdiction immobilises everyone already holding there: they could neither sell nor be bought out. Seizing or immobilising an existing position is the job of the freeze and recovery machinery, which is deliberate, targeted, and auditable. The end-to-end consequence is walked in [`test_scenario_closingAJurisdictionBlocksInboundOnly`](../../test/scenario/Lifecycle.t.sol#L334).

**The country-zero case** is worth its own note. An address with no registry record reads back `0`, which is not a real ISO code. The module treats it as unrestricted rather than special-casing it, because rejecting it here would be the wrong rule answering the question: an unregistered recipient is stopped by the token's identity check, not by a jurisdiction rule. The test asserts both halves: unrestricted by default, and blockable if an operator wants to.

The zero-amount case is review finding 12: every module's check lets a zero amount through, and the token's own identity and freeze checks still apply to it. See [`test_zeroAmountTransfer_toBlockedCountry_succeeds`](../../test/scenario/Regressions.t.sol#L627).

---

## Rule admin

| Test | Asserts |
| :--- | :------ |
| [`test_setCountryRestricted_updatesAndEmits`](../../test/unit/CountryRestrictionModule.t.sol#L154) | The agent blocks a country, `isRestricted` reads true, and `CountryRestrictionUpdated` fires |
| [`test_setCountryRestricted_revertsForNonAgent`](../../test/unit/CountryRestrictionModule.t.sol#L165) | The blocklist is agent-gated (`AccessControlUnauthorizedAccount` with `AGENT_ROLE`) |
| [`test_setCountryRestricted_revertsForIssuer`](../../test/unit/CountryRestrictionModule.t.sol#L174) | **The issuer is admin but not agent**, so the sanctions list is not theirs to write |

The issuer test is the same principle as in the registry: `DEFAULT_ADMIN_ROLE` is the power to *assign* roles, not to exercise them. A sanctions list belongs to the compliance desk that maintains it, and the separation is only real if it is tested from the admin's side too.

---

## Hook access

| Test | Asserts |
| :--- | :------ |
| [`test_hooks_revertForNonCompliance`](../../test/unit/CountryRestrictionModule.t.sol#L188) | All three lifecycle hooks revert `OnlyCompliance(caller, engine)` for a caller that is not the bound engine |
| [`test_hooks_acceptComplianceAndDoNothing`](../../test/unit/CountryRestrictionModule.t.sol#L203) | Called by the engine, the three hooks complete and the verdict for the same transfer is still true |

This module is stateless, so its hooks do nothing, and they are still gated. The reasoning is in the test's own comment: an ungated hook on a stateless module today becomes an ungated hook on a stateful one after a single refactor.

---

## Fuzz

| Test | Asserts |
| :--- | :------ |
| [`testFuzz_moduleCheck_mirrorsBlocklist`](../../test/unit/CountryRestrictionModule.t.sol#L218) | For any non-zero country code and either blocklist state, the verdict for a recipient registered there is the negation of the blocklist entry |
| [`testFuzz_restrictionsAreIndependent`](../../test/unit/CountryRestrictionModule.t.sol#L232) | For any two distinct codes, blocking one leaves a recipient registered in the other allowed |

The second guards against a mapping keyed or masked incorrectly: the kind of bug where blocking country 250 also blocks 25 or 2500. Point tests with two or three hand-picked codes would not reliably surface it.
