# Identity Registry (Phase 1)

**Suites:** [`IdentityRegistryTest`](../../test/unit/IdentityRegistry.t.sol) (40 unit + 4 fuzz)
**Covers:** roadmap items 1.1 to 1.2 · [Guide 2, EIP-712 digest](../02-mathematics.md) · [Guide 3, the registry](../03-architecture.md)

---

> The registry answers one question the token asks on every movement: may this address hold the instrument, and is that still true? It is a projection of an off-chain KYC process, so the tests concentrate on two things the chain *can* enforce — who is allowed to write a claim, and how a written claim goes stale. A signed attestation is a bearer credential, which is why replay closure gets more tests than the happy path.

## Constructor (1.1)

| Test | Asserts |
| :--- | :------ |
| [`test_constructor_grantsRoles`](../../test/unit/IdentityRegistry.t.sol#L86) | The issuer receives `DEFAULT_ADMIN_ROLE` and the agent `AGENT_ROLE`, as distinct accounts |
| [`test_constructor_revertsOnZeroIssuer`](../../test/unit/IdentityRegistry.t.sol#L91) | A zero issuer reverts `ZeroAddress`: a registry with no admin can never grant a role |
| [`test_constructor_revertsOnZeroAgent`](../../test/unit/IdentityRegistry.t.sol#L96) | A zero agent reverts `ZeroAddress` |

---

## The agent door (1.1)

An `AGENT_ROLE` holder writes records directly. This is the operational path the compliance desk uses.

| Test | Asserts |
| :--- | :------ |
| [`test_registerIdentity_storesRecordAndEmits`](../../test/unit/IdentityRegistry.t.sol#L105) | The record is stored with every field, and `IdentityRegistered` fires with the derived investor id |
| [`test_registerIdentity_overwritesExistingRecord`](../../test/unit/IdentityRegistry.t.sol#L123) | Re-registering an existing investor overwrites in place: a renewal is an update, not a duplicate |
| [`test_registerIdentity_revertsForNonAgent`](../../test/unit/IdentityRegistry.t.sol#L200) | A stranger cannot write the registry, asserting the exact `AccessControlUnauthorizedAccount` selector with the role |
| [`test_registerIdentity_revertsForIssuerWithoutAgentRole`](../../test/unit/IdentityRegistry.t.sol#L209) | **The issuer is admin, but admin is not agent.** Roles are not implicit: holding `DEFAULT_ADMIN_ROLE` grants the power to *assign* `AGENT_ROLE`, not to exercise it |
| [`test_registerIdentity_revertsOnZeroInvestor`](../../test/unit/IdentityRegistry.t.sol#L217) | A zero investor address is refused |
| [`test_registerIdentity_revertsOnPastExpiry`](../../test/unit/IdentityRegistry.t.sol#L224) | An already-stale attestation is rejected at the door rather than written as a dead record |
| [`test_registerIdentity_revertsOnExpiryEqualToNow`](../../test/unit/IdentityRegistry.t.sol#L231) | The boundary is exclusive: an expiry equal to `block.timestamp` is already stale |

The last two matter because `isVerified` is computed, not stored: writing a record whose expiry has passed would create a row that reads as unverified from the moment it exists. Rejecting it at the door keeps "a record exists" and "a record is usable" from drifting apart silently.

---

## The signed door (1.2)

Anyone may *submit* an attestation carrying the claim signer's EIP-712 signature. Authorisation comes from the signature, not the caller, which is what lets an investor self-register through a relayer.

### The happy path

| Test | Asserts |
| :--- | :------ |
| [`test_registerWithAttestation_acceptsValidSignatureFromAnySubmitter`](../../test/unit/IdentityRegistry.t.sol#L242) | A relayer holding **no role at all** successfully registers an investor with a valid signature, and the nonce advances to 1 |
| [`test_registerWithAttestation_consecutiveAttestationsAdvanceNonce`](../../test/unit/IdentityRegistry.t.sol#L396) | Three consecutive registrations each succeed against the advanced nonce, so the replay guard does not block legitimate renewals |
| [`test_nonces_areIndependentPerInvestor`](../../test/unit/IdentityRegistry.t.sol#L406) | Nonces are per-investor: one investor's activity never invalidates another's pending attestation |

### Replay closure, the three axes

A signature is a bearer credential valid until something invalidates it. Three axes must be closed, and each has its own test.

| Axis | Closed by | Test | Asserts |
| :--- | :-------- | :--- | :------ |
| **Space** (deployment) | domain separator | [`test_registerWithAttestation_signatureIsBoundToThisContract`](../../test/unit/IdentityRegistry.t.sol#L367) | A signature valid on this registry is rejected by a second deployment of the same code, and the two domain separators differ |
| **Space** (chain) | domain separator | [`test_registerWithAttestation_signatureIsBoundToChainId`](../../test/unit/IdentityRegistry.t.sol#L382) | Changing `block.chainid` changes the separator and invalidates the signature, so a testnet attestation cannot be replayed on mainnet |
| **Time** | `kycExpiry` | [`test_registerWithAttestation_revertsOnExpiredAttestation`](../../test/unit/IdentityRegistry.t.sol#L335) | An attestation warped past its expiry reverts `AttestationExpired`, exactly like the agent path |
| **Sequence** | per-investor nonce | [`test_registerWithAttestation_revertsOnReusedNonce`](../../test/unit/IdentityRegistry.t.sol#L272) | The same signature bytes fail on second use, because the consumed nonce changed the digest |

**The nonce's reason to exist** is [`test_registerWithAttestation_replayCannotResurrectRemovedInvestor`](../../test/unit/IdentityRegistry.t.sol#L289), the most load-bearing test in this suite. An agent removes a compromised investor; the *same* still-unexpired signature is replayed. Without the nonce it would silently re-register them, undoing the removal — the expiry alone cannot close that window, because the whole point is that the attestation has not expired yet. The test asserts the investor stays unverified after the replay attempt.

### Tampering

Every signed field is covered, because a signature only protects the fields inside the digest.

| Test | Asserts |
| :--- | :------ |
| [`test_registerWithAttestation_revertsOnRogueSigner`](../../test/unit/IdentityRegistry.t.sol#L259) | A signature from a key that is not the claim signer is rejected, naming both the recovered and expected addresses |
| [`test_registerWithAttestation_revertsOnTamperedCountry`](../../test/unit/IdentityRegistry.t.sol#L309) | Changing the country breaks recovery: an investor cannot be relocated to an unrestricted jurisdiction |
| [`test_registerWithAttestation_revertsOnTamperedAccreditation`](../../test/unit/IdentityRegistry.t.sol#L317) | Flipping the accreditation flag breaks recovery: a retail investor cannot self-promote |
| [`test_registerWithAttestation_revertsOnSubstitutedInvestor`](../../test/unit/IdentityRegistry.t.sol#L326) | An attestation for one investor cannot register another, so a submitter cannot redirect a claim to a wallet they control |
| [`test_registerWithAttestation_revertsOnMalformedSignature`](../../test/unit/IdentityRegistry.t.sol#L347) | Garbage signature bytes revert `ECDSAInvalidSignatureLength` rather than recovering `address(0)` and comparing against an unset signer |
| [`test_registerWithAttestation_revertsWhenNoClaimSigner`](../../test/unit/IdentityRegistry.t.sol#L354) | On a fresh registry with no signer configured, the signed path reverts `ClaimSignerNotSet` instead of accepting anything that recovers to zero |

The last two are the same class of bug seen from both sides: a naive implementation compares `ecrecover(...) == _claimSigner`, and when both sides are zero, an invalid signature registers a valid identity.

---

## Investor identity

An `investorId` stands in for ERC-3643's ONCHAINID. Two wallets sharing one belong to the same person, which is precisely what makes [forced recovery](./07-security-token.md#forced-recovery-45) safe.

| Test | Asserts |
| :--- | :------ |
| [`test_investorId_defaultsToDerivedFromWallet`](../../test/unit/IdentityRegistry.t.sol#L141) | A wallet registered without an explicit id gets `keccak256(investor)`, making it its own investor |
| [`test_investorId_explicitZeroDerivesDefault`](../../test/unit/IdentityRegistry.t.sol#L176) | Passing zero explicitly takes the same derived default, so the two registration overloads agree |
| [`test_investorId_isZeroForUnregisteredWallet`](../../test/unit/IdentityRegistry.t.sol#L148) | An unregistered wallet reads back zero, which is why callers comparing two ids must reject zero rather than treat it as a match |
| [`test_investorId_linksTwoWalletsUnderSharedId`](../../test/unit/IdentityRegistry.t.sol#L153) | Two wallets registered under the same explicit id are linked as one investor |
| [`test_investorId_differsForSeparatelyRegisteredWallets`](../../test/unit/IdentityRegistry.t.sol#L166) | Separately registered wallets never collide, so an accidental match is impossible |
| [`test_investorId_attestationBindsIdToSignature`](../../test/unit/IdentityRegistry.t.sol#L185) | The id is inside the signed payload: reusing a valid signature with a different id fails, then succeeds with the attested one |

**Why derive rather than store zero.** If an unlinked wallet stored `bytes32(0)`, then two unlinked wallets would compare equal, and a recovery check of the form `idOf(lost) == idOf(new)` would pass for two completely unrelated investors. Deriving from the address means every verified record carries a non-zero, unique-by-default id, so the comparison is meaningful without a special case. The last test is the security-relevant one: linking a wallet to an existing investor is an attested claim, never a submitter's choice.

---

## Removal

| Test | Asserts |
| :--- | :------ |
| [`test_removeIdentity_clearsRecordAndEmits`](../../test/unit/IdentityRegistry.t.sol#L424) | The record is fully cleared and `IdentityRemoved` fires |
| [`test_removeIdentity_revertsWhenNotFound`](../../test/unit/IdentityRegistry.t.sol#L441) | Removing an investor who was never registered reverts `IdentityNotFound` rather than succeeding silently |
| [`test_removeIdentity_revertsForNonAgent`](../../test/unit/IdentityRegistry.t.sol#L448) | Removal is agent-gated |

Removal does not touch balances — the registry has no knowledge of the token, and the dependency runs the other way. The consequence for a holder who loses their identity is enforced in the token's gate and documented under [the transfer gate](./07-security-token.md#the-transfer-gate-42-43).

---

## Expiry

`isVerified` is `verified && kycExpiry > block.timestamp`, computed on read rather than stored.

| Test | Asserts |
| :--- | :------ |
| [`test_isVerified_trueOneSecondBeforeExpiry`](../../test/unit/IdentityRegistry.t.sol#L476) | Still verified one second before expiry |
| [`test_isVerified_falseAfterExpiry`](../../test/unit/IdentityRegistry.t.sol#L464) | Unverified once the expiry passes, with no transaction required to flip it |
| [`test_isVerified_falseForUnknownInvestor`](../../test/unit/IdentityRegistry.t.sol#L484) | An address that was never registered reads as unverified |

The property that matters: a stale attestation stops being valid **without anyone acting**. A stored boolean would require an agent to notice and revoke, so the registry's claim would outlive the underlying fact.

---

## Claim signer rotation

| Test | Asserts |
| :--- | :------ |
| [`test_setClaimSigner_updatesAndEmits`](../../test/unit/IdentityRegistry.t.sol#L492) | The issuer rotates the signer and `ClaimSignerUpdated` names both the old and new addresses |
| [`test_setClaimSigner_revertsForAgent`](../../test/unit/IdentityRegistry.t.sol#L505) | The agent cannot rotate the signer: writing records and deciding who may attest are different powers |
| [`test_setClaimSigner_revertsOnZeroAddress`](../../test/unit/IdentityRegistry.t.sol#L515) | Rotating to zero is refused, which would otherwise re-open the "invalid signature recovers to the unset signer" hole |
| [`test_setClaimSigner_rotationInvalidatesOldSignatures`](../../test/unit/IdentityRegistry.t.sol#L522) | **Rotation is the revocation mechanism.** Every attestation signed by the previous key stops being accepted immediately |

That last test is why a single claim signer is a defensible scope decision rather than an oversight: compromise of the signing key is contained by one issuer transaction, and every outstanding signature dies with it. The cost — no per-issuer or per-claim-type granularity — is stated in [Guide 4](../04-tradeoffs.md).

---

## Fuzz

| Test | Property |
| :--- | :------- |
| [`testFuzz_registerIdentity_roundTrips`](../../test/unit/IdentityRegistry.t.sol#L539) | Any valid `(country, accredited, expiry)` combination written by an agent reads back identical |
| [`testFuzz_isVerified_tracksExpiryBoundary`](../../test/unit/IdentityRegistry.t.sol#L555) | Across arbitrary expiries and timestamps, `isVerified` is exactly `expiry > now`, with no off-by-one |
| [`testFuzz_registerWithAttestation_onlyClaimSignerAccepted`](../../test/unit/IdentityRegistry.t.sol#L567) | For any private key, the attestation is accepted if and only if that key is the configured claim signer |
| [`testFuzz_registerWithAttestation_submitterIsIrrelevant`](../../test/unit/IdentityRegistry.t.sol#L581) | For any submitter address, a valid signature registers: the caller genuinely does not matter |

The last two are the fuzzed statement of the design claim that authorisation lives in the signature and not in the caller — asserted over the whole key and address space rather than at the two or three points the unit tests pick.
