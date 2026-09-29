// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, Vm} from "forge-std/Test.sol";

import {DocumentRegistry} from "../../src/DocumentRegistry.sol";
import {IDocumentRegistry} from "../../src/interfaces/IDocumentRegistry.sol";

/**
 * @title ERC1643ConformanceTest
 * @notice Checks DocumentRegistry against the ERC-1643 issue text (ethereum/EIPs#1643).
 * @dev Differences, asserted below and documented in docs/04-tradeoffs.md:
 *
 *      - `DocumentRemoved(bytes32)` here; the issue has `DocumentRemoved(bytes32,string,bytes32)`,
 *        carrying the removed document's URI and hash.
 *      - `getDocument` returns the timestamp as `uint64`; the issue says `uint256`. The ABI
 *        encoding is identical (one 32-byte word), so a caller decoding `uint256` reads it.
 *      - The issue calls the hash optional; here a zero hash and an empty URI are rejected, since
 *        the point of this registry is to anchor content.
 *      - `getDocument` on an unknown name reverts with `DocumentNotFound`; the issue does not say.
 *
 *      Matching: `setDocument`, `removeDocument` and `getAllDocuments` signatures and semantics,
 *      and `DocumentUpdated(bytes32,string,bytes32)`.
 */
contract ERC1643ConformanceTest is Test {
    DocumentRegistry internal registry;
    address internal issuer = makeAddr("issuer");

    bytes32 internal constant NAME = bytes32("TERMS");
    string internal constant URI = "ipfs://QmTerms";
    bytes32 internal constant HASH = keccak256("terms v1");

    function setUp() public {
        vm.warp(1_700_000_000);
        registry = new DocumentRegistry(issuer);
    }

    /// @dev `setDocument` stores the document and emits `DocumentUpdated` with its details, whose
    ///      signature matches the issue's.
    function test_setDocument_emitsStandardEvent() public {
        assertEq(IDocumentRegistry.DocumentUpdated.selector, keccak256("DocumentUpdated(bytes32,string,bytes32)"));
        vm.expectEmit(true, false, false, true, address(registry));
        emit IDocumentRegistry.DocumentUpdated(NAME, URI, HASH);
        vm.prank(issuer);
        registry.setDocument(NAME, URI, HASH);
    }

    /// @dev `getDocument` returns (uri, hash, lastModified). Decoded with the issue's return types,
    ///      the timestamp reads the same.
    function test_getDocument_decodesWithTheIssueTypes() public {
        vm.prank(issuer);
        registry.setDocument(NAME, URI, HASH);

        (bool ok, bytes memory ret) =
            address(registry).staticcall(abi.encodeWithSignature("getDocument(bytes32)", NAME));
        assertTrue(ok);
        (string memory uri, bytes32 hash, uint256 lastModified) = abi.decode(ret, (string, bytes32, uint256));
        assertEq(uri, URI);
        assertEq(hash, HASH);
        assertEq(lastModified, block.timestamp);
    }

    /// @dev Re-anchoring a name updates it in place and emits `DocumentUpdated` again.
    function test_setDocument_updatesExisting() public {
        vm.startPrank(issuer);
        registry.setDocument(NAME, URI, HASH);
        vm.warp(block.timestamp + 1 days);
        registry.setDocument(NAME, "ipfs://QmTermsV2", keccak256("terms v2"));
        vm.stopPrank();

        (string memory uri, bytes32 hash, uint64 lastModified) = registry.getDocument(NAME);
        assertEq(uri, "ipfs://QmTermsV2");
        assertEq(hash, keccak256("terms v2"));
        assertEq(lastModified, block.timestamp);
        assertEq(registry.getAllDocuments().length, 1);
    }

    /// @dev `removeDocument` removes the name, throws if it was not stored, and emits
    ///      `DocumentRemoved`, whose signature differs from the issue's.
    function test_removeDocument_semanticsMatch_eventDiffers() public {
        vm.prank(issuer);
        registry.setDocument(NAME, URI, HASH);

        vm.recordLogs();
        vm.prank(issuer);
        registry.removeDocument(NAME);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs[0].topics[0], keccak256("DocumentRemoved(bytes32)"));
        assertTrue(logs[0].topics[0] != keccak256("DocumentRemoved(bytes32,string,bytes32)"), "now matches the issue");
        assertEq(registry.getAllDocuments().length, 0);

        vm.expectRevert(abi.encodeWithSelector(IDocumentRegistry.DocumentNotFound.selector, NAME));
        vm.prank(issuer);
        registry.removeDocument(NAME);
    }

    /// @dev "Any document added via setDocument and not subsequently removed ... MUST be returned."
    function test_getAllDocuments_returnsEveryLiveDocument() public {
        vm.startPrank(issuer);
        registry.setDocument(bytes32("A"), URI, HASH);
        registry.setDocument(bytes32("B"), URI, HASH);
        registry.setDocument(bytes32("C"), URI, HASH);
        registry.removeDocument(bytes32("B"));
        vm.stopPrank();

        bytes32[] memory names = registry.getAllDocuments();
        assertEq(names.length, 2);
        assertTrue(
            (names[0] == bytes32("A") && names[1] == bytes32("C"))
                || (names[0] == bytes32("C") && names[1] == bytes32("A"))
        );
    }

    /// @dev Stricter than the issue: an empty hash or URI is refused, and an unknown name reverts.
    function test_stricterInputs() public {
        vm.startPrank(issuer);
        vm.expectRevert(IDocumentRegistry.EmptyContentHash.selector);
        registry.setDocument(NAME, URI, bytes32(0));
        vm.expectRevert(IDocumentRegistry.EmptyDocumentUri.selector);
        registry.setDocument(NAME, "", HASH);
        vm.stopPrank();

        vm.expectRevert(abi.encodeWithSelector(IDocumentRegistry.DocumentNotFound.selector, NAME));
        registry.getDocument(NAME);
    }
}
