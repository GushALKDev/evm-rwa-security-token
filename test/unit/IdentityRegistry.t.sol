// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import {IdentityRegistry} from "../../src/identity/IdentityRegistry.sol";
import {IIdentityRegistry} from "../../src/interfaces/IIdentityRegistry.sol";
import {Roles} from "../../src/Roles.sol";

contract IdentityRegistryTest is Test {
    IdentityRegistry internal registry;

    address internal issuer = makeAddr("issuer");
    address internal agent = makeAddr("agent");
    address internal investor = makeAddr("investor");
    address internal relayer = makeAddr("relayer");
    address internal stranger = makeAddr("stranger");

    uint256 internal signerKey;
    address internal signer;
    uint256 internal rogueKey;

    uint16 internal constant ES = 724; // Spain, ISO 3166-1 numeric
    uint64 internal futureExpiry;

    function setUp() public {
        (signer, signerKey) = makeAddrAndKey("claimSigner");
        (, rogueKey) = makeAddrAndKey("rogueSigner");

        // Start at a realistic timestamp: the default of 1 makes expiry arithmetic misleading.
        vm.warp(1_700_000_000);
        futureExpiry = uint64(block.timestamp + 365 days);

        registry = new IdentityRegistry(issuer, agent);

        vm.prank(issuer);
        registry.setClaimSigner(signer);
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Builds an EIP-712 attestation signature for the investor's current nonce.
    function _sign(uint256 key, address who, uint16 country_, bool accredited, uint64 expiry)
        internal
        view
        returns (bytes memory)
    {
        return _signWithNonce(key, who, country_, accredited, expiry, bytes32(0), registry.nonces(who));
    }

    /// @dev As _sign, but binding an explicit investor id instead of letting the registry derive one.
    function _signWithId(uint256 key, address who, uint16 country_, bool accredited, uint64 expiry, bytes32 id)
        internal
        view
        returns (bytes memory)
    {
        return _signWithNonce(key, who, country_, accredited, expiry, id, registry.nonces(who));
    }

    function _signWithNonce(
        uint256 key,
        address who,
        uint16 country_,
        bool accredited,
        uint64 expiry,
        bytes32 id,
        uint256 nonce
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(registry.ATTESTATION_TYPEHASH(), who, country_, accredited, expiry, id, nonce)
        );
        bytes32 digest = MessageHashUtils.toTypedDataHash(registry.domainSeparator(), structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    function test_constructor_grantsRoles() public view {
        assertTrue(registry.hasRole(registry.DEFAULT_ADMIN_ROLE(), issuer));
        assertTrue(registry.hasRole(Roles.AGENT_ROLE, agent));
    }

    function test_constructor_revertsOnZeroIssuer() public {
        vm.expectRevert(IIdentityRegistry.ZeroAddress.selector);
        new IdentityRegistry(address(0), agent);
    }

    function test_constructor_revertsOnZeroAgent() public {
        vm.expectRevert(IIdentityRegistry.ZeroAddress.selector);
        new IdentityRegistry(issuer, address(0));
    }

    /*//////////////////////////////////////////////////////////////
                          AGENT REGISTRATION PATH
    //////////////////////////////////////////////////////////////*/

    function test_registerIdentity_storesRecordAndEmits() public {
        vm.expectEmit(true, true, false, true, address(registry));
        emit IIdentityRegistry.IdentityRegistered(
            investor, ES, true, futureExpiry, keccak256(abi.encode(investor)), false
        );

        vm.prank(agent);
        registry.registerIdentity(investor, ES, true, futureExpiry);

        IIdentityRegistry.Identity memory rec = registry.identity(investor);
        assertTrue(rec.verified);
        assertTrue(rec.accredited);
        assertEq(rec.country, ES);
        assertEq(rec.kycExpiry, futureExpiry);
        assertTrue(registry.isVerified(investor));
        assertEq(registry.country(investor), ES);
    }

    function test_registerIdentity_overwritesExistingRecord() public {
        vm.startPrank(agent);
        registry.registerIdentity(investor, ES, true, futureExpiry);
        registry.registerIdentity(investor, 250, false, futureExpiry + 1 days);
        vm.stopPrank();

        IIdentityRegistry.Identity memory rec = registry.identity(investor);
        assertEq(rec.country, 250);
        assertFalse(rec.accredited);
        assertEq(rec.kycExpiry, futureExpiry + 1 days);
    }

    /*//////////////////////////////////////////////////////////////
                              INVESTOR ID
    //////////////////////////////////////////////////////////////*/

    /// @dev A wallet registered without an explicit id is its own investor. Deriving rather than
    ///      storing zero keeps every verified record carrying a non-zero id.
    function test_investorId_defaultsToDerivedFromWallet() public {
        vm.prank(agent);
        registry.registerIdentity(investor, ES, true, futureExpiry);

        assertEq(registry.investorId(investor), keccak256(abi.encode(investor)));
    }

    function test_investorId_isZeroForUnregisteredWallet() public view {
        assertEq(registry.investorId(stranger), bytes32(0));
    }

    /// @dev Two wallets registered under the same explicit id are two wallets of one investor.
    function test_investorId_linksTwoWalletsUnderSharedId() public {
        bytes32 sharedId = keccak256("investor-alpha");

        vm.startPrank(agent);
        registry.registerIdentity(investor, ES, true, futureExpiry, sharedId);
        registry.registerIdentity(stranger, ES, true, futureExpiry, sharedId);
        vm.stopPrank();

        assertEq(registry.investorId(investor), sharedId);
        assertEq(registry.investorId(stranger), sharedId);
    }

    /// @dev Separately registered wallets are distinct investors, never accidental matches.
    function test_investorId_differsForSeparatelyRegisteredWallets() public {
        vm.startPrank(agent);
        registry.registerIdentity(investor, ES, true, futureExpiry);
        registry.registerIdentity(stranger, ES, true, futureExpiry);
        vm.stopPrank();

        assertTrue(registry.investorId(investor) != registry.investorId(stranger));
    }

    /// @dev Passing zero explicitly takes the derived default, matching the four-parameter door.
    function test_investorId_explicitZeroDerivesDefault() public {
        vm.prank(agent);
        registry.registerIdentity(investor, ES, true, futureExpiry, bytes32(0));

        assertEq(registry.investorId(investor), keccak256(abi.encode(investor)));
    }

    /// @dev The id is part of the signed payload: a submitter cannot swap it to attach a wallet
    ///      to an investor the claim signer never attested to.
    function test_investorId_attestationBindsIdToSignature() public {
        bytes32 sharedId = keccak256("investor-alpha");
        bytes memory sig = _signWithId(signerKey, investor, ES, true, futureExpiry, sharedId);

        // Same signature, different id: the digest no longer matches, so the recovery fails.
        vm.expectRevert();
        vm.prank(relayer);
        registry.registerIdentityWithAttestation(investor, ES, true, futureExpiry, keccak256("investor-beta"), sig);

        vm.prank(relayer);
        registry.registerIdentityWithAttestation(investor, ES, true, futureExpiry, sharedId, sig);
        assertEq(registry.investorId(investor), sharedId);
    }

    /// @dev Negative: a non-agent cannot write the registry.
    function test_registerIdentity_revertsForNonAgent() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, Roles.AGENT_ROLE)
        );
        vm.prank(stranger);
        registry.registerIdentity(investor, ES, true, futureExpiry);
    }

    /// @dev Negative: the issuer is admin, but admin is not agent. Roles are not implicit.
    function test_registerIdentity_revertsForIssuerWithoutAgentRole() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, issuer, Roles.AGENT_ROLE)
        );
        vm.prank(issuer);
        registry.registerIdentity(investor, ES, true, futureExpiry);
    }

    function test_registerIdentity_revertsOnZeroInvestor() public {
        vm.expectRevert(IIdentityRegistry.ZeroAddress.selector);
        vm.prank(agent);
        registry.registerIdentity(address(0), ES, true, futureExpiry);
    }

    /// @dev Negative: registering an already-stale attestation is rejected at the door.
    function test_registerIdentity_revertsOnPastExpiry() public {
        uint64 stale = uint64(block.timestamp - 1);
        vm.expectRevert(abi.encodeWithSelector(IIdentityRegistry.AttestationExpired.selector, stale, block.timestamp));
        vm.prank(agent);
        registry.registerIdentity(investor, ES, true, stale);
    }

    function test_registerIdentity_revertsOnExpiryEqualToNow() public {
        uint64 now_ = uint64(block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(IIdentityRegistry.AttestationExpired.selector, now_, now_));
        vm.prank(agent);
        registry.registerIdentity(investor, ES, true, now_);
    }

    /*//////////////////////////////////////////////////////////////
                         SIGNED ATTESTATION PATH
    //////////////////////////////////////////////////////////////*/

    function test_registerWithAttestation_acceptsValidSignatureFromAnySubmitter() public {
        bytes memory sig = _sign(signerKey, investor, ES, true, futureExpiry);

        vm.expectEmit(true, true, false, true, address(registry));
        emit IIdentityRegistry.IdentityRegistered(
            investor, ES, true, futureExpiry, keccak256(abi.encode(investor)), true
        );

        // Submitted by a relayer with no role: authorization comes from the signature.
        vm.prank(relayer);
        registry.registerIdentityWithAttestation(investor, ES, true, futureExpiry, bytes32(0), sig);

        assertTrue(registry.isVerified(investor));
        assertEq(registry.nonces(investor), 1);
    }

    /// @dev Negative: a signature from a key that is not the claim signer is rejected.
    function test_registerWithAttestation_revertsOnRogueSigner() public {
        bytes memory sig = _sign(rogueKey, investor, ES, true, futureExpiry);

        vm.expectRevert(
            abi.encodeWithSelector(IIdentityRegistry.InvalidAttestationSigner.selector, vm.addr(rogueKey), signer)
        );
        vm.prank(relayer);
        registry.registerIdentityWithAttestation(investor, ES, true, futureExpiry, bytes32(0), sig);

        assertFalse(registry.isVerified(investor));
    }

    /// @dev Negative: replaying a consumed attestation fails, because the nonce moved on.
    function test_registerWithAttestation_revertsOnReusedNonce() public {
        bytes memory sig = _sign(signerKey, investor, ES, true, futureExpiry);

        vm.prank(relayer);
        registry.registerIdentityWithAttestation(investor, ES, true, futureExpiry, bytes32(0), sig);

        // The consumed nonce changes the digest, so the same bytes now recover a different
        // address and fail the signer check. Assert the selector, not just "it reverted".
        vm.prank(relayer);
        vm.expectPartialRevert(IIdentityRegistry.InvalidAttestationSigner.selector);
        registry.registerIdentityWithAttestation(investor, ES, true, futureExpiry, bytes32(0), sig);
    }

    /**
     * @dev The scenario the nonce exists for: an agent removes an investor, and a replayed
     *      attestation must not silently re-register them inside the validity window.
     */
    function test_registerWithAttestation_replayCannotResurrectRemovedInvestor() public {
        bytes memory sig = _sign(signerKey, investor, ES, true, futureExpiry);

        vm.prank(relayer);
        registry.registerIdentityWithAttestation(investor, ES, true, futureExpiry, bytes32(0), sig);
        assertTrue(registry.isVerified(investor));

        vm.prank(agent);
        registry.removeIdentity(investor);
        assertFalse(registry.isVerified(investor));

        // Same signature, still inside its expiry window, now against nonce 1.
        vm.prank(relayer);
        vm.expectPartialRevert(IIdentityRegistry.InvalidAttestationSigner.selector);
        registry.registerIdentityWithAttestation(investor, ES, true, futureExpiry, bytes32(0), sig);

        assertFalse(registry.isVerified(investor));
    }

    /// @dev Negative: tampering with any signed field breaks recovery.
    function test_registerWithAttestation_revertsOnTamperedCountry() public {
        bytes memory sig = _sign(signerKey, investor, ES, true, futureExpiry);

        vm.prank(relayer);
        vm.expectPartialRevert(IIdentityRegistry.InvalidAttestationSigner.selector);
        registry.registerIdentityWithAttestation(investor, 250, true, futureExpiry, bytes32(0), sig);
    }

    function test_registerWithAttestation_revertsOnTamperedAccreditation() public {
        bytes memory sig = _sign(signerKey, investor, ES, false, futureExpiry);

        vm.prank(relayer);
        vm.expectPartialRevert(IIdentityRegistry.InvalidAttestationSigner.selector);
        registry.registerIdentityWithAttestation(investor, ES, true, futureExpiry, bytes32(0), sig);
    }

    /// @dev Negative: an attestation for one investor cannot register another.
    function test_registerWithAttestation_revertsOnSubstitutedInvestor() public {
        bytes memory sig = _sign(signerKey, investor, ES, true, futureExpiry);

        vm.prank(relayer);
        vm.expectPartialRevert(IIdentityRegistry.InvalidAttestationSigner.selector);
        registry.registerIdentityWithAttestation(stranger, ES, true, futureExpiry, bytes32(0), sig);
    }

    /// @dev Negative: a signed attestation that is already stale is rejected like the agent path.
    function test_registerWithAttestation_revertsOnExpiredAttestation() public {
        uint64 stale = uint64(block.timestamp + 1 days);
        bytes memory sig = _sign(signerKey, investor, ES, true, stale);

        vm.warp(stale + 1);

        vm.expectRevert(abi.encodeWithSelector(IIdentityRegistry.AttestationExpired.selector, stale, block.timestamp));
        vm.prank(relayer);
        registry.registerIdentityWithAttestation(investor, ES, true, stale, bytes32(0), sig);
    }

    /// @dev Negative: malformed signature bytes revert rather than recovering address(0).
    function test_registerWithAttestation_revertsOnMalformedSignature() public {
        vm.prank(relayer);
        vm.expectPartialRevert(ECDSA.ECDSAInvalidSignatureLength.selector);
        registry.registerIdentityWithAttestation(investor, ES, true, futureExpiry, bytes32(0), hex"dead");
    }

    /// @dev Negative: the signed path is unusable before a claim signer is configured.
    function test_registerWithAttestation_revertsWhenNoClaimSigner() public {
        IdentityRegistry fresh = new IdentityRegistry(issuer, agent);
        bytes memory sig = _sign(signerKey, investor, ES, true, futureExpiry);

        vm.expectRevert(IIdentityRegistry.ClaimSignerNotSet.selector);
        vm.prank(relayer);
        fresh.registerIdentityWithAttestation(investor, ES, true, futureExpiry, bytes32(0), sig);
    }

    /**
     * @dev The domain separator's reason to exist: a signature valid on this registry must not
     *      be replayable against a different deployment of the same code.
     */
    function test_registerWithAttestation_signatureIsBoundToThisContract() public {
        bytes memory sig = _sign(signerKey, investor, ES, true, futureExpiry);

        IdentityRegistry other = new IdentityRegistry(issuer, agent);
        vm.prank(issuer);
        other.setClaimSigner(signer);

        assertTrue(registry.domainSeparator() != other.domainSeparator());

        vm.prank(relayer);
        vm.expectPartialRevert(IIdentityRegistry.InvalidAttestationSigner.selector);
        other.registerIdentityWithAttestation(investor, ES, true, futureExpiry, bytes32(0), sig);
    }

    /// @dev The other half of the domain separator: no replay across chains.
    function test_registerWithAttestation_signatureIsBoundToChainId() public {
        bytes memory sig = _sign(signerKey, investor, ES, true, futureExpiry);
        bytes32 separatorBefore = registry.domainSeparator();

        vm.chainId(block.chainid + 1);

        assertTrue(registry.domainSeparator() != separatorBefore);

        vm.prank(relayer);
        vm.expectPartialRevert(IIdentityRegistry.InvalidAttestationSigner.selector);
        registry.registerIdentityWithAttestation(investor, ES, true, futureExpiry, bytes32(0), sig);
    }

    /// @dev Consecutive attestations work, each against the advanced nonce.
    function test_registerWithAttestation_consecutiveAttestationsAdvanceNonce() public {
        for (uint256 i; i < 3; ++i) {
            bytes memory sig = _sign(signerKey, investor, ES, true, futureExpiry);
            vm.prank(relayer);
            registry.registerIdentityWithAttestation(investor, ES, true, futureExpiry, bytes32(0), sig);
            assertEq(registry.nonces(investor), i + 1);
        }
    }

    /// @dev Nonces are per-investor, so one investor's activity cannot invalidate another's.
    function test_nonces_areIndependentPerInvestor() public {
        bytes memory sigA = _sign(signerKey, investor, ES, true, futureExpiry);
        vm.prank(relayer);
        registry.registerIdentityWithAttestation(investor, ES, true, futureExpiry, bytes32(0), sigA);

        assertEq(registry.nonces(investor), 1);
        assertEq(registry.nonces(stranger), 0);

        bytes memory sigB = _sign(signerKey, stranger, ES, true, futureExpiry);
        vm.prank(relayer);
        registry.registerIdentityWithAttestation(stranger, ES, true, futureExpiry, bytes32(0), sigB);
        assertTrue(registry.isVerified(stranger));
    }

    /*//////////////////////////////////////////////////////////////
                                REMOVAL
    //////////////////////////////////////////////////////////////*/

    function test_removeIdentity_clearsRecordAndEmits() public {
        vm.prank(agent);
        registry.registerIdentity(investor, ES, true, futureExpiry);

        vm.expectEmit(true, false, false, false, address(registry));
        emit IIdentityRegistry.IdentityRemoved(investor);

        vm.prank(agent);
        registry.removeIdentity(investor);

        IIdentityRegistry.Identity memory rec = registry.identity(investor);
        assertFalse(rec.verified);
        assertEq(rec.country, 0);
        assertEq(rec.kycExpiry, 0);
        assertFalse(registry.isVerified(investor));
    }

    function test_removeIdentity_revertsWhenNotFound() public {
        vm.expectRevert(abi.encodeWithSelector(IIdentityRegistry.IdentityNotFound.selector, investor));
        vm.prank(agent);
        registry.removeIdentity(investor);
    }

    /// @dev Negative: removal is agent-gated.
    function test_removeIdentity_revertsForNonAgent() public {
        vm.prank(agent);
        registry.registerIdentity(investor, ES, true, futureExpiry);

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, Roles.AGENT_ROLE)
        );
        vm.prank(stranger);
        registry.removeIdentity(investor);
    }

    /*//////////////////////////////////////////////////////////////
                                EXPIRY
    //////////////////////////////////////////////////////////////*/

    /// @dev Expired KYC is treated as unverified without any transaction touching the record.
    function test_isVerified_falseAfterExpiry() public {
        vm.prank(agent);
        registry.registerIdentity(investor, ES, true, futureExpiry);
        assertTrue(registry.isVerified(investor));

        vm.warp(futureExpiry);
        assertFalse(registry.isVerified(investor), "expiry boundary is exclusive");

        // The record still exists: expiry is a view-time judgement, not a deletion.
        assertTrue(registry.identity(investor).verified);
    }

    function test_isVerified_trueOneSecondBeforeExpiry() public {
        vm.prank(agent);
        registry.registerIdentity(investor, ES, true, futureExpiry);

        vm.warp(futureExpiry - 1);
        assertTrue(registry.isVerified(investor));
    }

    function test_isVerified_falseForUnknownInvestor() public view {
        assertFalse(registry.isVerified(stranger));
    }

    /*//////////////////////////////////////////////////////////////
                              CLAIM SIGNER
    //////////////////////////////////////////////////////////////*/

    function test_setClaimSigner_updatesAndEmits() public {
        address newSigner = makeAddr("newSigner");

        vm.expectEmit(true, true, false, false, address(registry));
        emit IIdentityRegistry.ClaimSignerUpdated(signer, newSigner);

        vm.prank(issuer);
        registry.setClaimSigner(newSigner);

        assertEq(registry.claimSigner(), newSigner);
    }

    /// @dev Negative: rotating the claim signer is an issuer power, not an agent one.
    function test_setClaimSigner_revertsForAgent() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, agent, registry.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(agent);
        registry.setClaimSigner(makeAddr("newSigner"));
    }

    function test_setClaimSigner_revertsOnZeroAddress() public {
        vm.expectRevert(IIdentityRegistry.ZeroAddress.selector);
        vm.prank(issuer);
        registry.setClaimSigner(address(0));
    }

    /// @dev Rotating the signer invalidates attestations signed by the previous one.
    function test_setClaimSigner_rotationInvalidatesOldSignatures() public {
        bytes memory sig = _sign(signerKey, investor, ES, true, futureExpiry);

        (address newSigner,) = makeAddrAndKey("newSigner");
        vm.prank(issuer);
        registry.setClaimSigner(newSigner);

        vm.expectRevert(abi.encodeWithSelector(IIdentityRegistry.InvalidAttestationSigner.selector, signer, newSigner));
        vm.prank(relayer);
        registry.registerIdentityWithAttestation(investor, ES, true, futureExpiry, bytes32(0), sig);
    }

    /*//////////////////////////////////////////////////////////////
                                  FUZZ
    //////////////////////////////////////////////////////////////*/

    /// @dev Property: any record written by an agent round-trips through storage unchanged.
    function testFuzz_registerIdentity_roundTrips(address who, uint16 country_, bool accredited, uint64 expiry) public {
        vm.assume(who != address(0));
        expiry = uint64(bound(expiry, block.timestamp + 1, type(uint64).max));

        vm.prank(agent);
        registry.registerIdentity(who, country_, accredited, expiry);

        IIdentityRegistry.Identity memory rec = registry.identity(who);
        assertEq(rec.country, country_);
        assertEq(rec.accredited, accredited);
        assertEq(rec.kycExpiry, expiry);
        assertTrue(rec.verified);
        assertTrue(registry.isVerified(who));
    }

    /// @dev Property: isVerified tracks the expiry boundary exactly, at any point in time.
    function testFuzz_isVerified_tracksExpiryBoundary(uint64 expiry, uint64 checkAt) public {
        expiry = uint64(bound(expiry, block.timestamp + 1, type(uint64).max));
        checkAt = uint64(bound(checkAt, 1, type(uint64).max));

        vm.prank(agent);
        registry.registerIdentity(investor, ES, true, expiry);

        vm.warp(checkAt);
        assertEq(registry.isVerified(investor), checkAt < expiry);
    }

    /// @dev Property: only the configured claim signer's signatures are ever accepted.
    function testFuzz_registerWithAttestation_onlyClaimSignerAccepted(uint256 key) public {
        key = bound(key, 1, type(uint128).max);
        vm.assume(vm.addr(key) != signer);

        bytes memory sig = _sign(key, investor, ES, true, futureExpiry);

        vm.prank(relayer);
        vm.expectPartialRevert(IIdentityRegistry.InvalidAttestationSigner.selector);
        registry.registerIdentityWithAttestation(investor, ES, true, futureExpiry, bytes32(0), sig);

        assertFalse(registry.isVerified(investor));
    }

    /// @dev Property: a valid attestation is accepted no matter who submits it.
    function testFuzz_registerWithAttestation_submitterIsIrrelevant(address submitter) public {
        vm.assume(submitter != address(0));
        bytes memory sig = _sign(signerKey, investor, ES, true, futureExpiry);

        vm.prank(submitter);
        registry.registerIdentityWithAttestation(investor, ES, true, futureExpiry, bytes32(0), sig);

        assertTrue(registry.isVerified(investor));
    }
}
