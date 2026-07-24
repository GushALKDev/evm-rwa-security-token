// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {DocumentRegistry} from "../../src/DocumentRegistry.sol";
import {IDocumentRegistry} from "../../src/interfaces/IDocumentRegistry.sol";

contract DocumentRegistryTest is Test {
    DocumentRegistry internal registry;

    address internal issuer = makeAddr("issuer");
    address internal attacker = makeAddr("attacker");

    bytes32 internal constant TERMS = bytes32("TERMS");
    bytes32 internal constant PROSPECTUS = bytes32("PROSPECTUS");

    string internal constant URI = "ipfs://QmTermsV1";
    bytes32 internal constant HASH = keccak256("terms content v1");

    function setUp() public {
        registry = new DocumentRegistry(issuer);
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _set(bytes32 name, string memory uri, bytes32 hash) internal {
        vm.prank(issuer);
        registry.setDocument(name, uri, hash);
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    function test_constructor_grantsAdminToIssuer() public view {
        assertTrue(registry.hasRole(registry.DEFAULT_ADMIN_ROLE(), issuer));
    }

    function test_constructor_revertsOnZeroIssuer() public {
        vm.expectRevert(IDocumentRegistry.ZeroAddress.selector);
        new DocumentRegistry(address(0));
    }

    /*//////////////////////////////////////////////////////////////
                              SET DOCUMENT
    //////////////////////////////////////////////////////////////*/

    function test_setDocument_storesRecord() public {
        _set(TERMS, URI, HASH);

        (string memory uri, bytes32 hash, uint64 lastModified) = registry.getDocument(TERMS);
        assertEq(uri, URI);
        assertEq(hash, HASH);
        assertEq(lastModified, uint64(block.timestamp));
    }

    function test_setDocument_indexesName() public {
        _set(TERMS, URI, HASH);

        bytes32[] memory names = registry.getAllDocuments();
        assertEq(names.length, 1);
        assertEq(names[0], TERMS);
    }

    function test_setDocument_emitsUpdated() public {
        vm.expectEmit(true, false, false, true, address(registry));
        emit IDocumentRegistry.DocumentUpdated(TERMS, URI, HASH);

        _set(TERMS, URI, HASH);
    }

    /// @dev Re-anchoring overwrites the record in place and does not create a duplicate index entry.
    function test_setDocument_reAnchorOverwritesWithoutDuplicating() public {
        _set(TERMS, URI, HASH);

        string memory newUri = "ipfs://QmTermsV2";
        bytes32 newHash = keccak256("terms content v2");
        skip(1 days);
        _set(TERMS, newUri, newHash);

        (string memory uri, bytes32 hash, uint64 lastModified) = registry.getDocument(TERMS);
        assertEq(uri, newUri);
        assertEq(hash, newHash);
        assertEq(lastModified, uint64(block.timestamp));

        assertEq(registry.getAllDocuments().length, 1);
    }

    function test_setDocument_revertsOnEmptyName() public {
        vm.expectRevert(IDocumentRegistry.EmptyDocumentName.selector);
        vm.prank(issuer);
        registry.setDocument(bytes32(0), URI, HASH);
    }

    function test_setDocument_revertsOnEmptyUri() public {
        vm.expectRevert(IDocumentRegistry.EmptyDocumentUri.selector);
        vm.prank(issuer);
        registry.setDocument(TERMS, "", HASH);
    }

    function test_setDocument_revertsOnEmptyHash() public {
        vm.expectRevert(IDocumentRegistry.EmptyContentHash.selector);
        vm.prank(issuer);
        registry.setDocument(TERMS, URI, bytes32(0));
    }

    /// @dev Negative: anchoring is issuer-gated.
    function test_setDocument_revertsForNonIssuer() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, registry.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(attacker);
        registry.setDocument(TERMS, URI, HASH);
    }

    /*//////////////////////////////////////////////////////////////
                            REMOVE DOCUMENT
    //////////////////////////////////////////////////////////////*/

    function test_removeDocument_clearsRecordAndIndex() public {
        _set(TERMS, URI, HASH);

        vm.prank(issuer);
        registry.removeDocument(TERMS);

        assertEq(registry.getAllDocuments().length, 0);

        vm.expectRevert(abi.encodeWithSelector(IDocumentRegistry.DocumentNotFound.selector, TERMS));
        registry.getDocument(TERMS);
    }

    function test_removeDocument_emitsRemoved() public {
        _set(TERMS, URI, HASH);

        vm.expectEmit(true, false, false, false, address(registry));
        emit IDocumentRegistry.DocumentRemoved(TERMS);

        vm.prank(issuer);
        registry.removeDocument(TERMS);
    }

    function test_removeDocument_revertsWhenNotFound() public {
        vm.expectRevert(abi.encodeWithSelector(IDocumentRegistry.DocumentNotFound.selector, TERMS));
        vm.prank(issuer);
        registry.removeDocument(TERMS);
    }

    /// @dev Negative: removal is issuer-gated.
    function test_removeDocument_revertsForNonIssuer() public {
        _set(TERMS, URI, HASH);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, registry.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(attacker);
        registry.removeDocument(TERMS);
    }

    /// @dev A re-anchor after removal starts a fresh record rather than resurrecting the old one.
    function test_removeThenSet_reindexes() public {
        _set(TERMS, URI, HASH);
        vm.prank(issuer);
        registry.removeDocument(TERMS);

        _set(TERMS, "ipfs://QmNew", keccak256("new"));

        bytes32[] memory names = registry.getAllDocuments();
        assertEq(names.length, 1);
        assertEq(names[0], TERMS);
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    function test_getDocument_revertsWhenNotFound() public {
        vm.expectRevert(abi.encodeWithSelector(IDocumentRegistry.DocumentNotFound.selector, PROSPECTUS));
        registry.getDocument(PROSPECTUS);
    }

    function test_getAllDocuments_enumeratesMultiple() public {
        _set(TERMS, URI, HASH);
        _set(PROSPECTUS, "ipfs://QmProspectus", keccak256("prospectus"));

        bytes32[] memory names = registry.getAllDocuments();
        assertEq(names.length, 2);
        assertEq(names[0], TERMS);
        assertEq(names[1], PROSPECTUS);
    }

    function test_getAllDocuments_emptyByDefault() public view {
        assertEq(registry.getAllDocuments().length, 0);
    }

    /*//////////////////////////////////////////////////////////////
                                  FUZZ
    //////////////////////////////////////////////////////////////*/

    /// @dev Property: a round-trip of set then read returns exactly what was written.
    function testFuzz_setThenGetRoundtrips(bytes32 name, string calldata uri, bytes32 hash) public {
        vm.assume(name != bytes32(0));
        vm.assume(bytes(uri).length != 0);
        vm.assume(hash != bytes32(0));

        _set(name, uri, hash);

        (string memory outUri, bytes32 outHash, uint64 lastModified) = registry.getDocument(name);
        assertEq(outUri, uri);
        assertEq(outHash, hash);
        assertEq(lastModified, uint64(block.timestamp));
    }

    /// @dev Property: the index size equals the count of distinct names anchored, never inflated by
    ///      re-anchors of the same name.
    function testFuzz_indexCountsDistinctNames(uint8 count) public {
        uint256 n = bound(count, 1, 30);

        // bytes32(i + 1) keeps the names distinct and non-zero (bytes32(0) would revert).
        for (uint256 i; i < n; ++i) {
            _set(bytes32(i + 1), URI, HASH);
        }
        assertEq(registry.getAllDocuments().length, n);

        // Re-anchor every name once: the index must not grow.
        for (uint256 i; i < n; ++i) {
            _set(bytes32(i + 1), "ipfs://QmV2", keccak256("v2"));
        }
        assertEq(registry.getAllDocuments().length, n);
    }
}
