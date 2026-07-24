// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IDocumentRegistry
 * @notice Anchors the off-chain legal documents that govern the token (prospectus, terms) to
 *         on-chain hashes.
 * @dev Simplified subset of ERC-1643 (the document management piece of the ERC-1400 family).
 *
 *      The hash is the keccak256 of the document CONTENT, not of the URI. This is the whole
 *      point: the URI says where the document lives, which is mutable and can be re-hosted, and
 *      the hash proves which exact version is legally in force. A holder can fetch the document,
 *      hash it, and compare. If the issuer silently edits the terms, the hash no longer matches
 *      and the substitution is evident on-chain.
 */
interface IDocumentRegistry {
    /*//////////////////////////////////////////////////////////////
                                 TYPES
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice An anchored document.
     * @param uri Where the document is published.
     * @param contentHash keccak256 of the document content.
     * @param lastModified Timestamp of the last update, for an audit trail.
     */
    struct Document {
        string uri;
        bytes32 contentHash;
        uint64 lastModified;
    }

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Emitted when a document is anchored or re-anchored.
     * @param name The document name, indexed for filtering.
     * @param uri Where the document is published.
     * @param contentHash keccak256 of the document content.
     */
    event DocumentUpdated(bytes32 indexed name, string uri, bytes32 contentHash);

    /**
     * @notice Emitted when a document anchor is removed.
     * @param name The document name.
     */
    event DocumentRemoved(bytes32 indexed name);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Thrown when the issuer address is zero at construction.
    error ZeroAddress();

    /// @notice Thrown when anchoring a document with an empty name.
    error EmptyDocumentName();

    /// @notice Thrown when anchoring a document with an empty URI.
    error EmptyDocumentUri();

    /// @notice Thrown when anchoring a document with a zero content hash.
    error EmptyContentHash();

    /// @notice Thrown when reading or removing a document that was never anchored.
    error DocumentNotFound(bytes32 name);

    /*//////////////////////////////////////////////////////////////
                            DOCUMENT MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Anchors a document, or re-anchors it to a new version.
     * @dev Restricted to the issuer (default admin). Re-anchoring is how a document is amended:
     *      the event log preserves the history of which version was in force when.
     * @param name The document name, a short label packed into bytes32 (for example bytes32("TERMS")),
     *             so it stays human readable when decoded off-chain rather than an opaque hash.
     * @param uri Where the document is published.
     * @param contentHash keccak256 of the document content, not of the URI.
     */
    function setDocument(bytes32 name, string calldata uri, bytes32 contentHash) external;

    /**
     * @notice Removes a document anchor.
     * @dev Restricted to the issuer (default admin).
     * @param name The document name.
     */
    function removeDocument(bytes32 name) external;

    /*//////////////////////////////////////////////////////////////
                                  VIEWS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Returns an anchored document.
     * @param name The document name.
     * @return uri Where the document is published.
     * @return contentHash keccak256 of the document content.
     * @return lastModified Timestamp of the last update.
     */
    function getDocument(bytes32 name)
        external
        view
        returns (string memory uri, bytes32 contentHash, uint64 lastModified);

    /**
     * @notice Returns the names of every anchored document.
     * @return The document names.
     */
    function getAllDocuments() external view returns (bytes32[] memory);
}
