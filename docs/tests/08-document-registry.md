# Document Registry (Phase 3)

**Suites:** [`DocumentRegistryTest`](../../test/unit/DocumentRegistry.t.sol) (18 unit + 2 fuzz)
**Covers:** roadmap item 3.1 · [Guide 3, document anchoring](../03-architecture.md)

---

> An ERC-1643 subset that binds the off-chain legal terms to the token by content hash. The hash is of the document **content**, never of the URI: the URI says where a document lives and can be re-hosted or moved, while the hash proves which exact version is legally in force. A holder can fetch the document, hash it, and compare. If the issuer silently amends the terms, the hashes stop matching and the substitution is evident on-chain.

How the registry lines up with the ERC-1643 interface itself (return types, events, where it is stricter) is in the [conformance suite](./16-conformance.md#erc-1643).

## Constructor

| Test | Asserts |
| :--- | :------ |
| [`test_constructor_grantsAdminToIssuer`](../../test/unit/DocumentRegistry.t.sol#L39) | The issuer receives `DEFAULT_ADMIN_ROLE` |
| [`test_constructor_revertsOnZeroIssuer`](../../test/unit/DocumentRegistry.t.sol#L43) | A zero issuer reverts `ZeroAddress` |

Anchoring is issuer-gated rather than agent-gated, unlike most of the system. Publishing the governing legal document is an act of the legally responsible party, not a day-to-day compliance operation.

---

## Anchoring a document (3.1)

| Test | Asserts |
| :--- | :------ |
| [`test_setDocument_storesRecord`](../../test/unit/DocumentRegistry.t.sol#L52) | URI, content hash and `lastModified` (the current block time) are all stored |
| [`test_setDocument_indexesName`](../../test/unit/DocumentRegistry.t.sol#L61) | The name joins the enumerable index, so the set of anchored documents is discoverable on-chain |
| [`test_setDocument_emitsUpdated`](../../test/unit/DocumentRegistry.t.sol#L69) | `DocumentUpdated` fires with the name, URI and hash |
| [`test_setDocument_reAnchorOverwritesWithoutDuplicating`](../../test/unit/DocumentRegistry.t.sol#L77) | **Re-anchoring is an upsert**: a day later, URI, hash and `lastModified` are replaced and the name appears exactly once in the index |
| [`test_setDocument_revertsOnEmptyName`](../../test/unit/DocumentRegistry.t.sol#L93) | A zero name reverts `EmptyDocumentName` |
| [`test_setDocument_revertsOnEmptyUri`](../../test/unit/DocumentRegistry.t.sol#L99) | An empty URI reverts `EmptyDocumentUri`: an anchor nobody can resolve is not an anchor |
| [`test_setDocument_revertsOnEmptyHash`](../../test/unit/DocumentRegistry.t.sol#L105) | A zero hash reverts `EmptyContentHash`, which would otherwise anchor "any document at all" |
| [`test_setDocument_revertsForNonIssuer`](../../test/unit/DocumentRegistry.t.sol#L112) | Anchoring is issuer-gated |

**Amendment is re-anchoring, and it is meant to be.** There is no separate `amendDocument`: the issuer calls `setDocument` again with the new hash and, if the location changed, the new URI. The event log is what preserves history: each `DocumentUpdated` records which version was in force from when, so the sequence of amendments is reconstructible off-chain without storing every version on-chain. This is why the suite asserts the index does not grow on re-anchor.

The three empty-value guards exist because each failure mode is silent. A zero hash anchors nothing while looking anchored; an empty URI leaves holders unable to fetch what they are meant to verify; a zero name cannot be looked up. A full 32-byte name and a 4 KiB URI are exercised in [`test_documents_longestNameAndLongUri`](../../test/scenario/EdgeCases.t.sol#L348).

---

## Removing an anchor

| Test | Asserts |
| :--- | :------ |
| [`test_removeDocument_clearsRecordAndIndex`](../../test/unit/DocumentRegistry.t.sol#L126) | The index is empty afterwards and reading the name reverts `DocumentNotFound` |
| [`test_removeDocument_emitsRemoved`](../../test/unit/DocumentRegistry.t.sol#L138) | `DocumentRemoved` fires |
| [`test_removeDocument_revertsWhenNotFound`](../../test/unit/DocumentRegistry.t.sol#L148) | Removing an unanchored name reverts `DocumentNotFound` rather than succeeding silently |
| [`test_removeDocument_revertsForNonIssuer`](../../test/unit/DocumentRegistry.t.sol#L155) | Removal is issuer-gated |
| [`test_removeThenSet_reindexes`](../../test/unit/DocumentRegistry.t.sol#L170) | With three names anchored, removing the first swaps the last into its slot and the moved name keeps its record; re-anchoring the removed name appends it with the new URI and hash, not the old record |

`setDocument` deliberately ignores whether the name was already present (both cases are valid), while `removeDocument` checks it and reverts. The asymmetry is intentional: re-anchoring an existing document is the normal amendment flow, whereas removing something that was never there means the caller is operating on a mistaken assumption and should hear about it.

The reindex test covers the state-machine edge of the underlying `EnumerableSet`: removing a name that is not last makes the set swap and pop, and the test checks both the moved entry and the fresh one.

---

## Views

| Test | Asserts |
| :--- | :------ |
| [`test_getDocument_revertsWhenNotFound`](../../test/unit/DocumentRegistry.t.sol#L202) | Reading an unanchored name reverts `DocumentNotFound` rather than returning an empty record that could be mistaken for a real anchor |
| [`test_getAllDocuments_enumeratesMultiple`](../../test/unit/DocumentRegistry.t.sol#L207) | Two anchored documents both appear in the enumeration, in anchoring order |
| [`test_getAllDocuments_emptyByDefault`](../../test/unit/DocumentRegistry.t.sol#L217) | A fresh registry enumerates empty |

Reverting on a missing document matters more than it looks. A zero-valued record would compare equal to a real one whose fields happen to be unset, so a caller checking "is this document anchored" by reading the hash could be told yes by a record that does not exist. ERC-1643 does not require the revert; the [conformance suite](./16-conformance.md#erc-1643) lists it among the places this registry is stricter.

---

## Fuzz

| Test | Asserts |
| :--- | :------ |
| [`testFuzz_setThenGetRoundtrips`](../../test/unit/DocumentRegistry.t.sol#L226) | Any non-empty `(name, uri, hash)` written reads back identical, with `lastModified` at the current block time |
| [`testFuzz_indexCountsDistinctNames`](../../test/unit/DocumentRegistry.t.sol#L241) | Over up to 60 steps interleaving new anchors, re-anchors and removals across eight names, after every step the index size equals the number of names currently anchored and every listed name is one of them |

The second is the upsert property stated over arbitrary sequences: however the issuer interleaves new anchors, amendments and removals, enumeration reflects the distinct live documents rather than write operations.

---

## The readable-name convention

Names are `bytes32` **labels**, not hashes: `bytes32("TERMS")`, not `keccak256("TERMS")`. A label under 32 bytes is reversible, so anything reading the chain can decode `getAllDocuments()` into human-readable names without a lookup table. A hashed name would be irreversible, forcing every consumer to already know the string it was looking for.

The content hash is a real `keccak256` of the document body. This convention is what [`test_anchor_nameIsReadableLabel`](../../test/unit/Deploy.t.sol#L266) pins at the deployment level.
