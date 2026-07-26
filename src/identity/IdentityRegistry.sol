// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

import {IIdentityRegistry} from "../interfaces/IIdentityRegistry.sol";
import {Roles} from "../Roles.sol";

/**
 * @title IdentityRegistry
 * @notice On-chain projection of an off-chain KYC/AML process: the set of investors allowed to
 *         hold the token, with the attributes compliance rules are evaluated against.
 * @dev Simplified stand-in for the ERC-3643 registry hierarchy (IdentityRegistry,
 *      IdentityRegistryStorage, TrustedIssuersRegistry, ClaimTopicsRegistry plus per-investor
 *      ONCHAINID contracts), collapsed into one flat registry. See the README for the scoping
 *      rationale.
 *
 *      Records arrive through two doors, mirroring two trust models:
 *      1. registerIdentity: an AGENT transcribes an off-chain KYC result. Trust rests on the
 *         agent's key.
 *      2. registerIdentityWithAttestation: anyone submits an EIP-712 payload signed by the
 *         authorized claim signer. Trust rests on the signature, not on the submitter. This is
 *         the ERC-3643 trust model in miniature.
 */
contract IdentityRegistry is IIdentityRegistry, AccessControl, EIP712 {
    using ECDSA for bytes32;

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice EIP-712 type hash for an identity attestation.
     * @dev The nonce is part of the signed struct: it is what stops a signature being replayed
     *      inside its validity window, for example to silently re-register an investor an agent
     *      had just removed. The expiry alone would not close that.
     */
    bytes32 public constant ATTESTATION_TYPEHASH = keccak256(
        "IdentityAttestation(address investor,uint16 country,bool accredited,uint64 kycExpiry,bytes32 investorId,uint256 nonce)"
    );

    /*//////////////////////////////////////////////////////////////
                                 STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @dev Investor records. Slot 0 holds the verification attributes read on every transfer.
    mapping(address investor => Identity record) private _identities;

    /// @dev Per-investor attestation nonce, incremented on every successful signed registration.
    mapping(address investor => uint256 nonce) private _nonces;

    /// @dev The single address authorized to sign attestations.
    address private _claimSigner;

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Deploys the registry.
     * @dev The EIP-712 domain binds chainId and this contract's address, so an attestation
     *      cannot be replayed against another chain or another registry deployment.
     * @param issuer The account receiving DEFAULT_ADMIN_ROLE.
     * @param agent The account receiving AGENT_ROLE.
     */
    constructor(address issuer, address agent) EIP712("IdentityRegistry", "1") {
        if (issuer == address(0) || agent == address(0)) revert ZeroAddress();

        _grantRole(DEFAULT_ADMIN_ROLE, issuer);
        _grantRole(Roles.AGENT_ROLE, agent);
    }

    /*//////////////////////////////////////////////////////////////
                            IDENTITY MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IIdentityRegistry
    function registerIdentity(address investor, uint16 country_, bool accredited, uint64 kycExpiry)
        external
        onlyRole(Roles.AGENT_ROLE)
    {
        _register(investor, country_, accredited, kycExpiry, bytes32(0), false);
    }

    /// @inheritdoc IIdentityRegistry
    function registerIdentity(address investor, uint16 country_, bool accredited, uint64 kycExpiry, bytes32 investorId_)
        external
        onlyRole(Roles.AGENT_ROLE)
    {
        _register(investor, country_, accredited, kycExpiry, investorId_, false);
    }

    /// @inheritdoc IIdentityRegistry
    function registerIdentityWithAttestation(
        address investor,
        uint16 country_,
        bool accredited,
        uint64 kycExpiry,
        bytes32 investorId_,
        bytes calldata signature
    ) external {
        address signer = _claimSigner;
        if (signer == address(0)) revert ClaimSignerNotSet();

        // Effects before the record write: consume the nonce so a replay of this exact payload
        // recovers a signature over a stale nonce and fails the signer check below.
        uint256 usedNonce = _nonces[investor]++;

        bytes32 digest = _hashTypedDataV4(
            keccak256(
                abi.encode(ATTESTATION_TYPEHASH, investor, country_, accredited, kycExpiry, investorId_, usedNonce)
            )
        );

        address recovered = digest.recover(signature);
        if (recovered != signer) revert InvalidAttestationSigner(recovered, signer);

        _register(investor, country_, accredited, kycExpiry, investorId_, true);
    }

    /// @inheritdoc IIdentityRegistry
    function removeIdentity(address investor) external onlyRole(Roles.AGENT_ROLE) {
        if (!_identities[investor].verified) revert IdentityNotFound(investor);

        delete _identities[investor];

        emit IdentityRemoved(investor);
    }

    /// @inheritdoc IIdentityRegistry
    function setClaimSigner(address newSigner) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newSigner == address(0)) revert ZeroAddress();

        address previous = _claimSigner;
        _claimSigner = newSigner;

        emit ClaimSignerUpdated(previous, newSigner);
    }

    /*//////////////////////////////////////////////////////////////
                                  VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IIdentityRegistry
    function isVerified(address investor) external view returns (bool) {
        Identity memory record = _identities[investor];

        // An attestation is a statement with a shelf life: a stale record is not a verified one.
        return record.verified && record.kycExpiry > block.timestamp;
    }

    /// @inheritdoc IIdentityRegistry
    function identity(address investor) external view returns (Identity memory) {
        return _identities[investor];
    }

    /// @inheritdoc IIdentityRegistry
    function country(address investor) external view returns (uint16) {
        return _identities[investor].country;
    }

    /// @inheritdoc IIdentityRegistry
    function investorId(address investor) external view returns (bytes32) {
        return _identities[investor].investorId;
    }

    /// @inheritdoc IIdentityRegistry
    function nonces(address investor) external view returns (uint256) {
        return _nonces[investor];
    }

    /// @inheritdoc IIdentityRegistry
    function claimSigner() external view returns (address) {
        return _claimSigner;
    }

    /**
     * @notice The EIP-712 domain separator for this registry.
     * @dev Exposed so an off-chain signer can build the digest without reconstructing the domain.
     * @return The domain separator.
     */
    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    /*//////////////////////////////////////////////////////////////
                                INTERNAL
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Shared write path for both registration doors, so the two cannot validate differently.
     *      The trailing underscore on countryCode is absent here: unlike the external functions,
     *      this scope has no country() getter to shadow.
     * @param investor The investor wallet.
     * @param countryCode ISO 3166-1 numeric country code.
     * @param accredited Accredited investor flag.
     * @param kycExpiry Expiry timestamp of the KYC attestation.
     * @param investorId_ Investor identifier, or zero to derive the default.
     * @param signed Whether this came from the signed path, for the event trail.
     */
    function _register(
        address investor,
        uint16 countryCode,
        bool accredited,
        uint64 kycExpiry,
        bytes32 investorId_,
        bool signed
    ) private {
        if (investor == address(0)) revert ZeroAddress();

        // Registering an already-stale record would write a row that isVerified rejects anyway.
        if (kycExpiry <= block.timestamp) revert AttestationExpired(kycExpiry, block.timestamp);

        // Default a wallet to being its own investor. Deriving from the address rather than
        // storing zero keeps the invariant that a verified record always carries a non-zero id,
        // so a comparison of two ids can never match on "both unset".
        bytes32 resolvedId = investorId_ == bytes32(0) ? keccak256(abi.encode(investor)) : investorId_;

        _identities[investor] = Identity({
            verified: true, accredited: accredited, country: countryCode, kycExpiry: kycExpiry, investorId: resolvedId
        });

        emit IdentityRegistered(investor, countryCode, accredited, kycExpiry, resolvedId, signed);
    }
}
