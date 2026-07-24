// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {IDocumentRegistry} from "./interfaces/IDocumentRegistry.sol";

/**
 * @title DocumentRegistry
 * @notice Anchors the off-chain legal documents that govern the token to on-chain content hashes.
 * @dev Simplified subset of ERC-1643. Each name maps to a {uri, contentHash, lastModified} record.
 *      The hash is of the document CONTENT, not the URI: the URI can be re-hosted freely, but a
 *      holder can fetch the document, hash it, and prove which exact version is in force. A silent
 *      amendment changes the content hash and is therefore evident on-chain.
 *
 *      Anchoring is restricted to the ISSUER (DEFAULT_ADMIN_ROLE). Re-anchoring an existing name is
 *      how a document is amended: the DocumentUpdated event log preserves which version was in
 *      force when, so the audit trail lives in events rather than in per-version storage.
 */
contract DocumentRegistry is IDocumentRegistry, AccessControl {
    using EnumerableSet for EnumerableSet.Bytes32Set;

    /*//////////////////////////////////////////////////////////////
                                 STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @dev The anchored record for each document name.
    mapping(bytes32 name => Document) private _documents;

    /// @dev The set of anchored names. Keeping the index separate from the records lets
    ///      getAllDocuments enumerate in O(n) while add/remove/membership stay O(1) and duplicate
    ///      names are impossible.
    EnumerableSet.Bytes32Set private _names;

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Deploys the registry.
     * @param issuer The account receiving DEFAULT_ADMIN_ROLE.
     */
    constructor(address issuer) {
        if (issuer == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, issuer);
    }

    /*//////////////////////////////////////////////////////////////
                            DOCUMENT MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IDocumentRegistry
    function setDocument(bytes32 name, string calldata uri, bytes32 contentHash) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (name == bytes32(0)) revert EmptyDocumentName();
        if (bytes(uri).length == 0) revert EmptyDocumentUri();
        if (contentHash == bytes32(0)) revert EmptyContentHash();

        // add() is a no-op returning false when the name already exists, so this upserts: a new
        // name joins the index, a re-anchor just overwrites the record below.
        _names.add(name);
        _documents[name] = Document({uri: uri, contentHash: contentHash, lastModified: uint64(block.timestamp)});

        emit DocumentUpdated(name, uri, contentHash);
    }

    /// @inheritdoc IDocumentRegistry
    function removeDocument(bytes32 name) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!_names.remove(name)) revert DocumentNotFound(name);
        delete _documents[name];

        emit DocumentRemoved(name);
    }

    /*//////////////////////////////////////////////////////////////
                                  VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IDocumentRegistry
    function getDocument(bytes32 name)
        external
        view
        returns (string memory uri, bytes32 contentHash, uint64 lastModified)
    {
        if (!_names.contains(name)) revert DocumentNotFound(name);
        Document storage doc = _documents[name];
        return (doc.uri, doc.contentHash, doc.lastModified);
    }

    /// @inheritdoc IDocumentRegistry
    function getAllDocuments() external view returns (bytes32[] memory) {
        return _names.values();
    }
}
