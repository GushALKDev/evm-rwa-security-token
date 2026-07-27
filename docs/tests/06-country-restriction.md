# Country Restriction Module (Phase 2)

**Suites:** [`CountryRestrictionModuleTest`](../../test/unit/CountryRestrictionModule.t.sol) (15 unit + 2 fuzz)
**Covers:** roadmap item 2.3 · [Guide 3, the pluggable seam](../03-architecture.md)

---

> A jurisdiction blocklist, and the only stateless rule in the set: it holds no clocks or counters, just a mapping of ISO 3166-1 numeric codes to a boolean. The tests are correspondingly short, and the interesting ones are all about a single design decision — the rule looks at the **recipient's** jurisdiction and never the sender's.

## Constructor

| Test | Asserts |
| :--- | :------ |
| [`test_constructor_setsState`](../../test/unit/CountryRestrictionModule.t.sol#L46) | Engine, registry and roles are set, and the module reports its name |
| [`test_constructor_revertsOnZeroRegistry`](../../test/unit/CountryRestrictionModule.t.sol#L54) | A zero registry is refused: country codes come from there, so the rule cannot function without it |
| [`test_constructor_revertsOnZeroCompliance`](../../test/unit/CountryRestrictionModule.t.sol#L59) | A zero engine reverts through the `AbstractComplianceModule` binding |

---

## Enforcement, and why it is recipient-side

| Test | Asserts |
| :--- | :------ |
| [`test_moduleCheck_allowsUnrestrictedCountry`](../../test/unit/CountryRestrictionModule.t.sol#L68) | With nothing blocked, transfers pass |
| [`test_moduleCheck_blocksRestrictedRecipient`](../../test/unit/CountryRestrictionModule.t.sol#L72) | A recipient in a blocked jurisdiction is refused |
| [`test_moduleCheck_ignoresSenderCountry`](../../test/unit/CountryRestrictionModule.t.sol#L82) | **The decision.** With the sender's own country blocked, they may still send; a blocked recipient still may not receive. Both directions asserted in one test |
| [`test_restrictionDoesNotAffectExistingHolders`](../../test/unit/CountryRestrictionModule.t.sol#L123) | Closing a jurisdiction does not trap the holders already there: they can still dispose of their position |
| [`test_moduleCheck_allowsBurn`](../../test/unit/CountryRestrictionModule.t.sol#L91) | A burn has no recipient to place in a jurisdiction, so the rule abstains |
| [`test_moduleCheck_unrestrictingRestoresTransfers`](../../test/unit/CountryRestrictionModule.t.sol#L111) | Reopening a jurisdiction restores transfers immediately: the measure is reversible |
| [`test_moduleCheck_unregisteredRecipientReadsAsCountryZero`](../../test/unit/CountryRestrictionModule.t.sol#L101) | An unregistered wallet reads as country `0`, which is unrestricted by default; blocking `0` explicitly does block it |

**Why the sender is ignored.** A distribution restriction governs who the instrument may be *placed with*, not who may exit. Blocking the sender's country too would mean that closing a jurisdiction confiscates the mobility of everyone already holding there — they could neither sell nor be bought out, and their position would be frozen by a rule that was never intended to freeze anything. Seizing or immobilising an existing position is the job of the freeze and recovery machinery, which is deliberate, targeted, and auditable. This module's job is narrower, and the two tests above pin exactly that boundary. The end-to-end consequence is walked in [`test_scenario_closingAJurisdictionBlocksInboundOnly`](../../test/scenario/Lifecycle.t.sol#L334).

**The country-zero case** is worth its own note. An address with no registry record reads back `0`, which is not a real ISO code. The module treats it as unrestricted rather than special-casing it, because rejecting it here would be the *wrong rule answering the question*: an unregistered recipient is stopped by the token's identity check, not by a jurisdiction rule. Each module answers exactly one question, and the test asserts both halves — unrestricted by default, and blockable if an operator genuinely wants to.

---

## Rule admin

| Test | Asserts |
| :--- | :------ |
| [`test_setCountryRestricted_updatesAndEmits`](../../test/unit/CountryRestrictionModule.t.sol#L134) | The agent blocks a country and `CountryRestrictionUpdated` fires |
| [`test_setCountryRestricted_revertsForNonAgent`](../../test/unit/CountryRestrictionModule.t.sol#L145) | The blocklist is agent-gated |
| [`test_setCountryRestricted_revertsForIssuer`](../../test/unit/CountryRestrictionModule.t.sol#L154) | **The issuer is admin but not agent**, so the sanctions list is not theirs to write |

The issuer test is the same principle as in the registry: `DEFAULT_ADMIN_ROLE` is the power to *assign* roles, not to exercise them. A sanctions list belongs to the compliance desk that maintains it, and the separation is only real if it is tested from the admin's side too.

---

## Hook access

| Test | Asserts |
| :--- | :------ |
| [`test_hooks_revertForNonCompliance`](../../test/unit/CountryRestrictionModule.t.sol#L168) | All three lifecycle hooks reject a caller that is not the bound engine |
| [`test_hooks_acceptComplianceAndDoNothing`](../../test/unit/CountryRestrictionModule.t.sol#L183) | Called by the engine, the hooks are no-ops and leave the verdict unchanged |

This module is stateless, so its hooks genuinely do nothing — and they are still gated. The reasoning is in the test's own comment: an ungated hook on a stateless module today becomes an ungated hook on a stateful one after a single refactor. The gate costs nothing and removes a class of future bug.

---

## Fuzz

| Test | Property |
| :--- | :------- |
| [`testFuzz_moduleCheck_mirrorsBlocklist`](../../test/unit/CountryRestrictionModule.t.sol#L198) | For any country code and any blocked/unblocked state, the verdict is exactly the negation of the blocklist entry |
| [`testFuzz_restrictionsAreIndependent`](../../test/unit/CountryRestrictionModule.t.sol#L212) | Blocking one country never affects a recipient in any other |

The second guards against a mapping keyed or masked incorrectly — the kind of bug where blocking country 250 also blocks 25 or 2500. Point tests with two or three hand-picked codes would not reliably surface it.
