# Standards Conformance (Review)

**Suites:** [`ERC20ConformanceTest`](../../test/conformance/ERC20Conformance.t.sol) (12) · [`ERC3643ConformanceTest`](../../test/conformance/ERC3643Conformance.t.sol) (10) · [`ERC1643ConformanceTest`](../../test/conformance/ERC1643Conformance.t.sol) (6) · [`EIP712ConformanceTest`](../../test/conformance/EIP712Conformance.t.sol) (6)
**Covers:** [Guide 4 §2.6](../04-tradeoffs.md#26-erc-3643-surface-implemented-and-not-implemented) · ERC-20 · ERC-3643 (T-REX) · ERC-1643 · EIP-712

---

> The unit suites test each contract against its own interface. These four test it against the standard it claims to follow, one suite per standard. Where the system matches, the test asserts the standard's behaviour. Where it differs by design, the test asserts this system's behaviour and names the standard's, so that a change in either direction makes the test fail and the documented difference has to be revisited. Events are compared by `topic0`, the `keccak256` of the canonical signature.

The ERC-20 and ERC-3643 suites run against the system [`Deploy`](../../script/Deploy.s.sol) produces, with the holders verified and the lockup already elapsed, so the compliance gate is satisfied and the standard's own behaviour is what the test sees. The ERC-1643 and EIP-712 suites build a single registry.

## ERC-20

The one systematic difference: a transfer the compliance gate refuses **reverts** with a custom error instead of returning `false`. ERC-20 allows either. Every refusal is covered in the unit suites; one is shown here.

| Test | Asserts |
| :--- | :------ |
| [`test_metadata`](../../test/conformance/ERC20Conformance.t.sol#L46) | Name and symbol are the deployment's, decimals are 18, and total supply is the minted amount |
| [`test_transfer_returnsTrueAndEmits`](../../test/conformance/ERC20Conformance.t.sol#L58) | `transfer` returns `true`, emits `Transfer(from, to, value)` and credits the recipient |
| [`test_approve_returnsTrueEmitsAndOverwrites`](../../test/conformance/ERC20Conformance.t.sol#L67) | `approve` returns `true` and emits `Approval`; a second `approve` overwrites the allowance rather than adding to it |
| [`test_transferFrom_returnsTrueConsumesAllowanceAndEmitsTransferOnly`](../../test/conformance/ERC20Conformance.t.sol#L80) | `transferFrom` returns `true`, reduces the allowance by the amount, and the token emits exactly one `Transfer` and no `Approval` (OpenZeppelin v5 behaviour, which ERC-20 permits) |
| [`test_transferFrom_unlimitedAllowanceIsNotConsumed`](../../test/conformance/ERC20Conformance.t.sol#L102) | An allowance of `type(uint256).max` is unchanged after a spend |
| [`test_transferFrom_beyondAllowanceReverts`](../../test/conformance/ERC20Conformance.t.sol#L111) | Spending 2 against an allowance of 1 reverts `ERC20InsufficientAllowance(spender, 1, 2)` |
| [`test_approve_zeroAddressReverts`](../../test/conformance/ERC20Conformance.t.sol#L120) | Approving the zero address reverts `ERC20InvalidSpender`, and approving from it reverts `ERC20InvalidApprover` |
| [`test_transfer_toZeroAddressReverts`](../../test/conformance/ERC20Conformance.t.sol#L132) | A transfer to the zero address reverts `ERC20InvalidReceiver`: burning is the issuer's `burn`, not a transfer to zero |
| [`test_zeroAmountTransfers_areNormalTransfers`](../../test/conformance/ERC20Conformance.t.sol#L144) | Zero-value `transfer` and `transferFrom` (the latter by a spender with no allowance) both return `true` and emit `Transfer`, as ERC-20 requires ("MUST be treated as normal transfers") |
| [`test_selfTransfer`](../../test/conformance/ERC20Conformance.t.sol#L157) | A self-transfer returns `true`, emits `Transfer(a, a, v)` and leaves the balance unchanged |
| [`test_mintAndBurn_emitTransferFromAndToZero`](../../test/conformance/ERC20Conformance.t.sol#L171) | Mint emits `Transfer` from the zero address and burn emits `Transfer` to it, and supply moves by the net amount |
| [`test_refusedTransfer_revertsInsteadOfReturningFalse`](../../test/conformance/ERC20Conformance.t.sol#L185) | **Difference by design**: a transfer to an unverified recipient reverts `RecipientNotVerified` rather than returning `false` |

The zero-amount test is the standard's side of review findings 1 and 12: zero-value transfers must stay ordinary transfers, which is why the fix for the holder count returns early in the hooks rather than refusing zero amounts at the gate.

---

## ERC-3643

The suite checks the functions [Guide 4 §2.6](../04-tradeoffs.md#26-erc-3643-surface-implemented-and-not-implemented) lists as implemented as in ERC-3643 against the EIP text, and compares each event this system emits for those operations with the one the EIP and the T-REX interfaces define.

| Test | Asserts |
| :--- | :------ |
| [`test_pause_blocksTransfersAndMatchesEvents`](../../test/conformance/ERC3643Conformance.t.sol#L89) | The agent's `pause` emits `Paused(address)` and `paused()` reads true, a transfer reverts `EnforcedPause`, and `unpause` emits `Unpaused(address)`: semantics and events **match** |
| [`test_setAddressFrozen_semanticsMatch_eventDiffers`](../../test/conformance/ERC3643Conformance.t.sol#L113) | A frozen recipient reverts `RecipientAddressFrozen` and a frozen sender `SenderAddressFrozen`, as the EIP requires; the event is `AddressFrozen(address,bool)`, **not** the standard's `AddressFrozen(address,bool,address)` with the acting agent |
| [`test_partialFreeze_semanticsAndEventsMatch`](../../test/conformance/ERC3643Conformance.t.sol#L138) | `TokensFrozen` and `TokensUnfrozen` have the standard signatures, and a transfer above the free balance reverts `InsufficientUnfrozenBalance`. The suite's comment notes the getter is `frozenTokens` where the standard has `getFrozenTokens`; that naming is not asserted |
| [`test_recoveryEvent_differs`](../../test/conformance/ERC3643Conformance.t.sol#L163) | The last event of `forcedRecovery` is `RecoverySuccess(address,address,uint256,uint256,bool)`, **not** the standard's `RecoverySuccess(address,address,address)` with the ONCHAINID |
| [`test_identityEvents_differ`](../../test/conformance/ERC3643Conformance.t.sol#L179) | Registration emits `IdentityRegistered(address,uint16,bool,uint64,bytes32,bool)` and removal `IdentityRemoved(address)`, **not** the standard's two-address forms: there is no `IIdentity` contract to name |
| [`test_isVerified_expires`](../../test/conformance/ERC3643Conformance.t.sol#L198) | `isVerified` is true for a one-day attestation and false once the day has passed: it reads a stored flag and an expiry rather than claims |
| [`test_moduleEvents_match`](../../test/conformance/ERC3643Conformance.t.sol#L213) | `addModule` emits `ModuleAdded(address)` on the engine and `ComplianceBound(address)` on the module; `removeModule` emits `ModuleRemoved(address)` and `ComplianceUnbound(address)`: these **match** T-REX |
| [`test_compliance_canTransferAndHookAccess`](../../test/conformance/ERC3643Conformance.t.sol#L233) | The engine's `canTransfer` follows the rule modules (false with the recipient's country blocked, true once reopened), and `transferred` called by anyone but the bound token reverts `OnlyToken` |
| [`test_tokenBoundEvent_sameSignatureIndexedHere`](../../test/conformance/ERC3643Conformance.t.sol#L247) | `TokenBound` has the standard signature `TokenBound(address)`; the suite's comment notes the address is indexed here and not in the standard, which a `topic0` comparison cannot show |
| [`test_moduleAttachmentApi`](../../test/conformance/ERC3643Conformance.t.sol#L253) | As in the T-REX `IModule`, `bindCompliance` from anyone but the engine reverts `OnlyCompliance`; the lockup reports not plug and play and cannot bind again, the country module reports plug and play and can |

The differences are all listed in [Guide 4 §2.6](../04-tradeoffs.md#26-erc-3643-surface-implemented-and-not-implemented). `IdentityRegistrySet` and `ComplianceSet` (emitted once, in the token constructor, where the standard has `IdentityRegistryAdded` and `ComplianceAdded` from its setters) are named in the suite's NatSpec but not asserted by a test.

---

## ERC-1643

The suite checks `DocumentRegistry` against the ERC-1643 issue text.

| Test | Asserts |
| :--- | :------ |
| [`test_setDocument_emitsStandardEvent`](../../test/conformance/ERC1643Conformance.t.sol#L40) | The `DocumentUpdated` selector equals `keccak256("DocumentUpdated(bytes32,string,bytes32)")`, and `setDocument` emits it with the name, URI and hash: **matches** |
| [`test_getDocument_decodesWithTheIssueTypes`](../../test/conformance/ERC1643Conformance.t.sol#L50) | The raw return of `getDocument`, decoded with the issue's types `(string, bytes32, uint256)`, gives the URI, hash and timestamp: the `uint64` here encodes to the same 32-byte word |
| [`test_setDocument_updatesExisting`](../../test/conformance/ERC1643Conformance.t.sol#L64) | Re-anchoring a name a day later replaces URI, hash and timestamp in place, and the name is listed once |
| [`test_removeDocument_semanticsMatch_eventDiffers`](../../test/conformance/ERC1643Conformance.t.sol#L80) | Removal emits `DocumentRemoved(bytes32)`, **not** the issue's `DocumentRemoved(bytes32,string,bytes32)`; the name leaves the list, and removing it again reverts `DocumentNotFound`, as the issue requires |
| [`test_getAllDocuments_returnsEveryLiveDocument`](../../test/conformance/ERC1643Conformance.t.sol#L98) | After anchoring three names and removing the middle one, the list holds exactly the other two, in either order ("MUST be returned") |
| [`test_stricterInputs`](../../test/conformance/ERC1643Conformance.t.sol#L115) | **Stricter than the issue**: a zero hash reverts `EmptyContentHash`, an empty URI `EmptyDocumentUri`, and reading an unknown name `DocumentNotFound` |

The issue calls the hash optional; this registry exists to anchor content, so it refuses an empty one. The unit-level tests for the same guards are in [Document Registry](./08-document-registry.md#anchoring-a-document-31).

---

## EIP-712

The suite checks the signed registration path against EIP-712 and the signature rules it relies on.

| Test | Asserts |
| :--- | :------ |
| [`test_domainSeparator_isTheEip712Formula`](../../test/conformance/EIP712Conformance.t.sol#L53) | `domainSeparator()` equals the EIP-712 hash over name `IdentityRegistry`, version `1`, the chain id and the registry's address, and the EIP-5267 `eip712Domain()` view reports the same fields |
| [`test_signature_isBoundToChainId`](../../test/conformance/EIP712Conformance.t.sol#L73) | A signature made before a chain id change reverts `InvalidAttestationSigner` after it |
| [`test_signature_isBoundToRegistryAddress`](../../test/conformance/EIP712Conformance.t.sol#L81) | A signature made for one registry reverts `InvalidAttestationSigner` on another with the same signer |
| [`test_expiryBoundary`](../../test/conformance/EIP712Conformance.t.sol#L93) | An attestation expiring at the current second reverts `AttestationExpired`; one expiring a second later registers, and reads as unverified from that second on |
| [`test_highSSignature_isRejected`](../../test/conformance/EIP712Conformance.t.sol#L108) | The malleable twin of a valid signature (`s` replaced by `n - s`, `v` flipped) reverts `ECDSAInvalidSignatureS`: only low-s signatures are accepted |
| [`test_contractSigner_isNotSupported`](../../test/conformance/EIP712Conformance.t.sol#L121) | **No EIP-1271.** With a contract that would approve any signature set as claim signer, a signature reverts `InvalidAttestationSigner(recovered, contractSigner)`: the registry only compares the ECDSA-recovered address |

The chain-id and registry-address bindings repeat the unit tests in [Identity Registry](./02-identity-registry.md#replay-closure-the-three-axes) so that the EIP-712 properties sit in one place. The EIP-1271 test pins a limitation, listed in the [gaps register](./12-gaps-and-roadmap.md#no-eip-1271-contract-signers).
