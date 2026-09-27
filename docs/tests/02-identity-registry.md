# Identity Registry (Phase 1)

**Suites:** [`IdentityRegistryTest`](../../test/unit/IdentityRegistry.t.sol) (44 unit + 4 fuzz)
**Covers:** roadmap items 1.1 to 1.2 · [Guide 2, EIP-712 digest](../02-mathematics.md) · [Guide 3, the registry](../03-architecture.md)

---

> The registry answers one question the token asks on every movement: may this address hold the instrument, and is that still true? It is a projection of an off-chain KYC process, so the tests concentrate on two things the chain *can* enforce, who is allowed to write a claim, and how a written claim goes stale. A signed attestation is a bearer credential, which is why replay closure gets more tests than the happy path.

## Constructor (1.1)

| Test | Asserts |
| :--- | :------ |
| [`test_constructor_grantsRoles`](../../test/unit/IdentityRegistry.t.sol#L86) | The issuer holds `DEFAULT_ADMIN_ROLE` and the agent holds `AGENT_ROLE` |
| [`test_constructor_revertsOnZeroIssuer`](../../test/unit/IdentityRegistry.t.sol#L91) | A zero issuer reverts `ZeroAddress`: a registry with no admin can never grant a role |
| [`test_constructor_revertsOnZeroAgent`](../../test/unit/IdentityRegistry.t.sol#L96) | A zero agent reverts `ZeroAddress` |

---

## The agent door (1.1)

An `AGENT_ROLE` holder writes records directly. This is the operational path the compliance desk uses.

| Test | Asserts |
| :--- | :------ |
| [`test_registerIdentity_storesRecordAndEmits`](../../test/unit/IdentityRegistry.t.sol#L105) | Every field of the record is stored, `isVerified` and `country` read it back, and `IdentityRegistered` fires with the derived investor id and `signed = false` |
| [`test_registerIdentity_overwritesExistingRecord`](../../test/unit/IdentityRegistry.t.sol#L123) | Re-registering an existing investor overwrites country, accreditation and expiry in place: a renewal is an update, not a duplicate |
| [`test_registerIdentity_revertsForNonAgent`](../../test/unit/IdentityRegistry.t.sol#L201) | A stranger cannot write the registry, asserting the exact `AccessControlUnauthorizedAccount` selector with the account and role |
| [`test_registerIdentity_revertsForIssuerWithoutAgentRole`](../../test/unit/IdentityRegistry.t.sol#L210) | **The issuer is admin, but admin is not agent.** Roles are not implicit: holding `DEFAULT_ADMIN_ROLE` grants the power to *assign* `AGENT_ROLE`, not to exercise it |
| [`test_registerIdentity_revertsOnZeroInvestor`](../../test/unit/IdentityRegistry.t.sol#L218) | A zero investor address reverts `ZeroAddress` |
| [`test_registerIdentity_revertsOnPastExpiry`](../../test/unit/IdentityRegistry.t.sol#L225) | An already-stale attestation reverts `AttestationExpired(expiry, now)` at the door rather than being written as a dead record |
| [`test_registerIdentity_revertsOnExpiryEqualToNow`](../../test/unit/IdentityRegistry.t.sol#L232) | The boundary is exclusive: an expiry equal to `block.timestamp` is already stale |

The last two matter because `isVerified` is computed, not stored: writing a record whose expiry has passed would create a row that reads as unverified from the moment it exists. Rejecting it at the door keeps "a record exists" and "a record is usable" from drifting apart silently.

---

## The signed door (1.2)

Anyone may *submit* an attestation carrying the claim signer's EIP-712 signature. Authorisation comes from the signature, not the caller, which is what lets an investor self-register through a relayer.

### The happy path

| Test | Asserts |
| :--- | :------ |
| [`test_registerWithAttestation_acceptsValidSignatureFromAnySubmitter`](../../test/unit/IdentityRegistry.t.sol#L243) | A relayer holding **no role at all** registers an investor with a valid signature, `IdentityRegistered` fires with `signed = true`, and the nonce advances to 1 |
| [`test_registerWithAttestation_consecutiveAttestationsAdvanceNonce`](../../test/unit/IdentityRegistry.t.sol#L397) | Three consecutive registrations each succeed against the advanced nonce, which reads 1, 2 and 3, so the replay guard does not block legitimate renewals |
| [`test_nonces_areIndependentPerInvestor`](../../test/unit/IdentityRegistry.t.sol#L438) | One investor's registration moves only their own nonce; a second investor's attestation, signed at nonce 0, still registers |
| [`test_nonces_advanceOnAgentWritesAndRemoval`](../../test/unit/IdentityRegistry.t.sol#L408) | **Every write advances the nonce**, not only a signed one: an agent registration, a second agent registration and a removal move it to 1, 2 and 3. Unit counterpart of review finding 2 |

### Replay closure, the three axes

A signature is a bearer credential valid until something invalidates it. Three axes must be closed, and each has its own test.

| Axis | Closed by | Test | Asserts |
| :--- | :-------- | :--- | :------ |
| **Space** (deployment) | domain separator | [`test_registerWithAttestation_signatureIsBoundToThisContract`](../../test/unit/IdentityRegistry.t.sol#L368) | The two domain separators differ, and a signature valid on this registry reverts `InvalidAttestationSigner` on a second deployment of the same code with the same claim signer |
| **Space** (chain) | domain separator | [`test_registerWithAttestation_signatureIsBoundToChainId`](../../test/unit/IdentityRegistry.t.sol#L383) | Changing `block.chainid` changes the separator and the signature then reverts `InvalidAttestationSigner`, so a testnet attestation cannot be replayed on mainnet |
| **Time** | `kycExpiry` | [`test_registerWithAttestation_revertsOnExpiredAttestation`](../../test/unit/IdentityRegistry.t.sol#L336) | An attestation warped past its expiry reverts `AttestationExpired(expiry, now)`, exactly like the agent path |
| **Sequence** | per-investor nonce | [`test_registerWithAttestation_revertsOnReusedNonce`](../../test/unit/IdentityRegistry.t.sol#L273) | The same signature bytes revert `InvalidAttestationSigner` on second use, because the consumed nonce changed the digest |
| **Sequence** | per-investor nonce | [`test_registerWithAttestation_replayCannotResurrectRemovedInvestor`](../../test/unit/IdentityRegistry.t.sol#L290) | After an agent removes a registered investor, the same unexpired signature reverts and the investor stays unverified |

**The nonce's reason to exist** is the last row, the most load-bearing test in this suite. An agent removes a compromised investor; the *same* still-unexpired signature is replayed. Without the nonce it would silently re-register them, undoing the removal: the expiry alone cannot close that window, because the whole point is that the attestation has not expired yet. Review finding 2 widened the same window to an attestation that was issued but never submitted; since the fix every write to a record advances the nonce, and the deployed-wiring regressions are in [Regressions](./14-regressions.md#2-an-unsubmitted-attestation-could-undo-a-removal).

Where the tampered payload makes the recovered address unpredictable, the tests use `expectPartialRevert` on the `InvalidAttestationSigner` selector instead of dropping the assertion.

### Tampering

Every signed field is covered, because a signature only protects the fields inside the digest.

| Test | Asserts |
| :--- | :------ |
| [`test_registerWithAttestation_revertsOnRogueSigner`](../../test/unit/IdentityRegistry.t.sol#L260) | A signature from a key that is not the claim signer reverts `InvalidAttestationSigner` naming both the recovered and the expected address, and the investor stays unverified |
| [`test_registerWithAttestation_revertsOnTamperedCountry`](../../test/unit/IdentityRegistry.t.sol#L310) | Changing the country breaks recovery: an investor cannot be relocated to an unrestricted jurisdiction |
| [`test_registerWithAttestation_revertsOnTamperedAccreditation`](../../test/unit/IdentityRegistry.t.sol#L318) | Flipping the accreditation flag breaks recovery: a retail investor cannot self-promote |
| [`test_registerWithAttestation_revertsOnSubstitutedInvestor`](../../test/unit/IdentityRegistry.t.sol#L327) | An attestation for one investor cannot register another, so a submitter cannot redirect a claim to a wallet they control |
| [`test_registerWithAttestation_revertsOnMalformedSignature`](../../test/unit/IdentityRegistry.t.sol#L348) | Two bytes of garbage revert `ECDSAInvalidSignatureLength` rather than recovering `address(0)` |
| [`test_registerWithAttestation_revertsWhenNoClaimSigner`](../../test/unit/IdentityRegistry.t.sol#L355) | On a fresh registry with no signer configured, the signed path reverts `ClaimSignerNotSet` |

The last two are the same class of bug seen from both sides: a naive implementation compares `ecrecover(...) == _claimSigner`, and when both sides are zero, an invalid signature registers a valid identity.

---

## Investor identity

An `investorId` stands in for ERC-3643's ONCHAINID. Two wallets sharing one belong to the same person, which is precisely what makes [forced recovery](./07-security-token.md#forced-recovery-45) safe.

| Test | Asserts |
| :--- | :------ |
| [`test_investorId_defaultsToDerivedFromWallet`](../../test/unit/IdentityRegistry.t.sol#L141) | A wallet registered without an explicit id gets `keccak256(abi.encode(investor))`, making it its own investor |
| [`test_investorId_explicitZeroDerivesDefault`](../../test/unit/IdentityRegistry.t.sol#L176) | Passing zero explicitly takes the same derived default, so the two registration overloads agree |
| [`test_investorId_isZeroForUnregisteredWallet`](../../test/unit/IdentityRegistry.t.sol#L148) | A wallet that was never registered reads back zero, which is why callers comparing two ids must reject zero rather than treat it as a match |
| [`test_investorId_linksTwoWalletsUnderSharedId`](../../test/unit/IdentityRegistry.t.sol#L153) | Two wallets registered under the same explicit id both read it back |
| [`test_investorId_differsForSeparatelyRegisteredWallets`](../../test/unit/IdentityRegistry.t.sol#L166) | Two wallets registered separately get different ids |
| [`test_investorId_attestationBindsIdToSignature`](../../test/unit/IdentityRegistry.t.sol#L185) | The id is inside the signed payload: reusing a valid signature with a different id reverts `InvalidAttestationSigner`, then the attested id registers and reads back |

**Why derive rather than store zero.** If an unlinked wallet stored `bytes32(0)`, then two unlinked wallets would compare equal, and a recovery check of the form `idOf(lost) == idOf(new)` would pass for two unrelated investors. Deriving from the address means every verified record carries a non-zero id that is distinct per wallet by default. The last test is the security-relevant one: linking a wallet to an existing investor is an attested claim, never a submitter's choice.

---

## Removal

| Test | Asserts |
| :--- | :------ |
| [`test_removeIdentity_clearsRecordAndEmits`](../../test/unit/IdentityRegistry.t.sol#L456) | `IdentityRemoved` fires, verification, accreditation, country and expiry are cleared and `isVerified` is false, while **the `investorId` survives** so recovery can still match the wallet (review finding 3) |
| [`test_removeIdentity_walletCanBeRegisteredAgain`](../../test/unit/IdentityRegistry.t.sol#L478) | A removed wallet is suspended, not banned: the agent registers it again with new attributes and it is verified |
| [`test_removeIdentity_revertsWhenAlreadyRemoved`](../../test/unit/IdentityRegistry.t.sol#L490) | Removing a wallet a second time reverts `IdentityNotFound`: there is nothing verified left to clear |
| [`test_removeIdentity_revertsWhenNotFound`](../../test/unit/IdentityRegistry.t.sol#L499) | Removing a wallet that was never registered reverts `IdentityNotFound` rather than succeeding silently |
| [`test_removeIdentity_revertsForNonAgent`](../../test/unit/IdentityRegistry.t.sol#L506) | Removal is agent-gated, asserted with the exact `AccessControlUnauthorizedAccount` error |

Removal does not touch balances: the registry has no knowledge of the token, and the dependency runs the other way. The consequence for a holder who loses their identity is enforced in the token's gate and documented under [the transfer gate](./07-security-token.md#the-transfer-gate-42-43). Keeping the `investorId` through removal is what lets a custodian recover a wallet the agent has already suspended, pinned end to end in [`test_forcedRecovery_succeedsAfterAgentRemovedLostWallet`](../../test/scenario/Regressions.t.sol#L213).

---

## Expiry

`isVerified` is `verified && kycExpiry > block.timestamp`, computed on read rather than stored.

| Test | Asserts |
| :--- | :------ |
| [`test_isVerified_trueOneSecondBeforeExpiry`](../../test/unit/IdentityRegistry.t.sol#L534) | Still verified one second before expiry |
| [`test_isVerified_falseAfterExpiry`](../../test/unit/IdentityRegistry.t.sol#L522) | Unverified exactly at the expiry timestamp, with no transaction required, while the stored record still reads `verified = true`: expiry is a view-time judgement, not a deletion |
| [`test_isVerified_falseForUnknownInvestor`](../../test/unit/IdentityRegistry.t.sol#L542) | An address that was never registered reads as unverified |
| [`test_isVerified_readsOneStorageSlot`](../../test/unit/IdentityRegistry.t.sol#L423) | With `vm.record`, every storage read `isVerified` makes is the same slot, so the investor id slot is never loaded. It counts distinct slots rather than raw reads because the unoptimized coverage build reads the slot once per field. Regression test for review finding 10 |

The property that matters: a stale attestation stops being valid **without anyone acting**. A stored boolean would require an agent to notice and revoke, so the registry's claim would outlive the underlying fact.

---

## Claim signer rotation

| Test | Asserts |
| :--- | :------ |
| [`test_setClaimSigner_updatesAndEmits`](../../test/unit/IdentityRegistry.t.sol#L550) | The issuer rotates the signer, `claimSigner()` returns the new one, and `ClaimSignerUpdated` names both the old and new addresses |
| [`test_setClaimSigner_revertsForAgent`](../../test/unit/IdentityRegistry.t.sol#L563) | The agent cannot rotate the signer (`AccessControlUnauthorizedAccount` with `DEFAULT_ADMIN_ROLE`): writing records and deciding who may attest are different powers |
| [`test_setClaimSigner_revertsOnZeroAddress`](../../test/unit/IdentityRegistry.t.sol#L573) | Rotating to zero reverts `ZeroAddress`, which would otherwise re-open the "invalid signature recovers to the unset signer" hole |
| [`test_setClaimSigner_rotationInvalidatesOldSignatures`](../../test/unit/IdentityRegistry.t.sol#L580) | **Rotation is the revocation mechanism.** An attestation signed by the previous key reverts `InvalidAttestationSigner(old, new)` immediately |

That last test is why a single claim signer is a defensible scope decision rather than an oversight: compromise of the signing key is contained by one issuer transaction, and every outstanding signature stops being accepted with it. The cost (no per-issuer or per-claim-type granularity) is stated in [Guide 4](../04-tradeoffs.md).

---

## Fuzz

| Test | Asserts |
| :--- | :------ |
| [`testFuzz_registerIdentity_roundTrips`](../../test/unit/IdentityRegistry.t.sol#L597) | Any non-zero wallet with any `(country, accredited, expiry)` written by an agent reads back identical and verified |
| [`testFuzz_isVerified_tracksExpiryBoundary`](../../test/unit/IdentityRegistry.t.sol#L613) | Across arbitrary expiries and timestamps, `isVerified` is exactly `now < expiry` |
| [`testFuzz_registerWithAttestation_onlyClaimSignerAccepted`](../../test/unit/IdentityRegistry.t.sol#L627) | For any private key in the secp256k1 range, the attestation is accepted if and only if that key is the configured claim signer. Half the runs make the fuzzed key the signer first, so both directions of the equivalence are exercised |
| [`testFuzz_registerWithAttestation_submitterIsIrrelevant`](../../test/unit/IdentityRegistry.t.sol#L646) | For any non-zero submitter address, a valid signature registers |

The last two are the fuzzed statement of the design claim that authorisation lives in the signature and not in the caller, asserted over the key and address space rather than at the two or three points the unit tests pick.
