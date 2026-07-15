// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IIdentityRegistry
 * @notice On-chain projection of an off-chain KYC/AML process: the set of investors allowed to
 *         hold the token, with the attributes compliance rules are evaluated against.
 * @dev Simplified stand-in for the ERC-3643 registry hierarchy. The reference standard splits
 *      this across IdentityRegistry, IdentityRegistryStorage, TrustedIssuersRegistry and
 *      ClaimTopicsRegistry, with a per-investor ONCHAINID contract holding signed claims. Here
 *      that is collapsed into one flat registry holding the attested attributes directly.
 *
 *      Two registration paths are exposed, mirroring the two trust models:
 *      1. An AGENT writes the record directly, transcribing an off-chain attestation. Trust
 *         rests on the agent.
 *      2. Anyone submits an EIP-712 attestation signed by the authorized claim signer. Trust
 *         rests on the signature, which is the ERC-3643 model in miniature: verification does
 *         not depend on trusting whoever submits the transaction.
 */
interface IIdentityRegistry {
    /*//////////////////////////////////////////////////////////////
                                 TYPES
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice The attested attributes of a verified investor.
     * @dev Packed into a single storage slot: every transfer reads this record, so the layout is
     *      chosen to make verification one SLOAD.
     * @param verified Whether a record exists and has been attested. Distinct from the expiry
     *        check: a record can exist yet be stale.
     * @param accredited Whether the investor qualifies as an accredited/professional investor.
     * @param country ISO 3166-1 numeric country code (integer, not string, to keep the record
     *        packed and comparisons cheap).
     * @param kycExpiry Unix timestamp after which the KYC attestation is stale and the investor
     *        is treated as unverified.
     */
    struct Identity {
        bool verified; //     1 byte ──┐
        bool accredited; //   1 byte   │  Slot 0 (12 bytes used of 32,
        uint16 country; //    2 bytes  │  the rest is padding)
        uint64 kycExpiry; //  8 bytes ─┘
    }

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Emitted when an investor record is created or overwritten.
     * @param investor The investor wallet.
     * @param country ISO 3166-1 numeric country code.
     * @param accredited Accredited investor flag.
     * @param kycExpiry Expiry timestamp of the KYC attestation.
     * @param signed True if registered via a signed attestation, false if written by an agent.
     */
    event IdentityRegistered(address indexed investor, uint16 country, bool accredited, uint64 kycExpiry, bool signed);

    /**
     * @notice Emitted when an investor record is deleted.
     * @param investor The investor wallet.
     */
    event IdentityRemoved(address indexed investor);

    /**
     * @notice Emitted when the authorized claim signer is changed.
     * @param previousSigner The previous claim signer.
     * @param newSigner The new claim signer.
     */
    event ClaimSignerUpdated(address indexed previousSigner, address indexed newSigner);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Thrown when the zero address is supplied where a real account is required.
    error ZeroAddress();

    /// @notice Thrown when an attestation signature does not recover to the authorized signer.
    error InvalidAttestationSigner(address recovered, address expected);

    /// @notice Thrown when registering an identity whose KYC expiry is already in the past.
    error AttestationExpired(uint64 kycExpiry, uint256 currentTime);

    /// @notice Thrown when removing or updating an investor that has no record.
    error IdentityNotFound(address investor);

    /// @notice Thrown when no claim signer has been configured but a signed path is used.
    error ClaimSignerNotSet();

    /*//////////////////////////////////////////////////////////////
                            IDENTITY MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Registers or overwrites an investor record directly.
     * @dev Restricted to AGENT. Represents an off-chain KYC provider whose attestation the
     *      compliance desk transcribes on-chain.
     * @param investor The investor wallet.
     * @param country ISO 3166-1 numeric country code.
     * @param accredited Accredited investor flag.
     * @param kycExpiry Expiry timestamp of the KYC attestation, must be in the future.
     */
    function registerIdentity(address investor, uint16 country, bool accredited, uint64 kycExpiry) external;

    /**
     * @notice Registers or overwrites an investor record from an EIP-712 signed attestation.
     * @dev Permissionless to submit: authorization comes from the signature, not the caller. The
     *      signed payload binds the investor, attributes, expiry and the investor's current
     *      nonce, under a domain separator carrying chainId and this contract's address. The
     *      nonce closes replay within the validity window (for example re-registration after a
     *      removal); the expiry alone would not.
     * @param investor The investor wallet.
     * @param country ISO 3166-1 numeric country code.
     * @param accredited Accredited investor flag.
     * @param kycExpiry Expiry timestamp of the KYC attestation, must be in the future.
     * @param signature The claim signer's EIP-712 signature over the attestation.
     */
    function registerIdentityWithAttestation(
        address investor,
        uint16 country,
        bool accredited,
        uint64 kycExpiry,
        bytes calldata signature
    ) external;

    /**
     * @notice Deletes an investor record.
     * @dev Restricted to AGENT. Also used by the token's recovery flow to retire a lost wallet.
     * @param investor The investor wallet.
     */
    function removeIdentity(address investor) external;

    /**
     * @notice Sets the address authorized to sign attestations.
     * @dev Restricted to the issuer (default admin). Collapses the ERC-3643 TrustedIssuersRegistry
     *      into a single trusted signer.
     * @param newSigner The new claim signer.
     */
    function setClaimSigner(address newSigner) external;

    /*//////////////////////////////////////////////////////////////
                                  VIEWS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Whether an investor is currently verified.
     * @dev An expired KYC attestation is treated as unverified: verification is a claim with a
     *      shelf life, not a permanent flag.
     * @param investor The investor wallet.
     * @return True if a record exists, is verified, and its KYC has not expired.
     */
    function isVerified(address investor) external view returns (bool);

    /**
     * @notice Returns the full stored record for an investor.
     * @param investor The investor wallet.
     * @return The identity record, zero-valued if none exists.
     */
    function identity(address investor) external view returns (Identity memory);

    /**
     * @notice Returns an investor's country code.
     * @param investor The investor wallet.
     * @return ISO 3166-1 numeric country code, zero if no record exists.
     */
    function country(address investor) external view returns (uint16);

    /**
     * @notice Returns the current attestation nonce for an investor.
     * @dev Must be included in the next EIP-712 attestation for this investor.
     * @param investor The investor wallet.
     * @return The current nonce.
     */
    function nonces(address investor) external view returns (uint256);

    /**
     * @notice Returns the address authorized to sign attestations.
     * @return The claim signer.
     */
    function claimSigner() external view returns (address);
}
