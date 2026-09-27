// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import {IdentityRegistry} from "../../src/identity/IdentityRegistry.sol";
import {IIdentityRegistry} from "../../src/interfaces/IIdentityRegistry.sol";

/**
 * @title EIP712ConformanceTest
 * @notice Checks the attestation path against EIP-712 and the signature rules it relies on.
 * @dev The chain-id binding is also covered in the registry unit suite
 *      (`test_registerWithAttestation_signatureIsBoundToChainId`); it is repeated here so the
 *      EIP-712 properties sit in one place. Contract signers (EIP-1271) are not supported: the
 *      registry recovers an ECDSA address and compares it with the claim signer, so a contract
 *      set as claim signer can never produce an accepted signature.
 */
contract EIP712ConformanceTest is Test {
    IdentityRegistry internal registry;
    address internal issuer = makeAddr("issuer");
    address internal agent = makeAddr("agent");
    address internal investor = makeAddr("investor");
    address internal signer;
    uint256 internal signerKey;
    uint64 internal expiry;
    uint16 internal constant ES = 724;

    function setUp() public {
        vm.warp(1_700_000_000);
        expiry = uint64(block.timestamp + 365 days);
        (signer, signerKey) = makeAddrAndKey("claimSigner");
        registry = new IdentityRegistry(issuer, agent);
        vm.prank(issuer);
        registry.setClaimSigner(signer);
    }

    function _digest(IdentityRegistry target, uint64 exp) internal view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(target.ATTESTATION_TYPEHASH(), investor, ES, true, exp, bytes32(0), target.nonces(investor))
        );
        return MessageHashUtils.toTypedDataHash(target.domainSeparator(), structHash);
    }

    function _sign(IdentityRegistry target, uint64 exp) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, _digest(target, exp));
        return abi.encodePacked(r, s, v);
    }

    /// @dev The domain separator is the EIP-712 one, over name, version, chain id and this
    ///      registry's address, and the EIP-5267 `eip712Domain` view reports the same fields.
    function test_domainSeparator_isTheEip712Formula() public view {
        bytes32 expected = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("IdentityRegistry"),
                keccak256("1"),
                block.chainid,
                address(registry)
            )
        );
        assertEq(registry.domainSeparator(), expected);

        (, string memory name, string memory version, uint256 chainId, address verifying,,) = registry.eip712Domain();
        assertEq(name, "IdentityRegistry");
        assertEq(version, "1");
        assertEq(chainId, block.chainid);
        assertEq(verifying, address(registry));
    }

    /// @dev A signature made before a chain id change is rejected after it.
    function test_signature_isBoundToChainId() public {
        bytes memory sig = _sign(registry, expiry);
        vm.chainId(block.chainid + 1);
        vm.expectPartialRevert(IIdentityRegistry.InvalidAttestationSigner.selector);
        registry.registerIdentityWithAttestation(investor, ES, true, expiry, bytes32(0), sig);
    }

    /// @dev A signature made for one registry is rejected by another with the same signer.
    function test_signature_isBoundToRegistryAddress() public {
        IdentityRegistry other = new IdentityRegistry(issuer, agent);
        vm.prank(issuer);
        other.setClaimSigner(signer);
        bytes memory sig = _sign(registry, expiry);

        vm.expectPartialRevert(IIdentityRegistry.InvalidAttestationSigner.selector);
        other.registerIdentityWithAttestation(investor, ES, true, expiry, bytes32(0), sig);
    }

    /// @dev Expiry boundary: an attestation expiring now is refused; one expiring a second later
    ///      is accepted and reads as unverified from its expiry second on.
    function test_expiryBoundary() public {
        uint64 nowTs = uint64(block.timestamp);
        bytes memory expiring = _sign(registry, nowTs);
        vm.expectRevert(abi.encodeWithSelector(IIdentityRegistry.AttestationExpired.selector, nowTs, block.timestamp));
        registry.registerIdentityWithAttestation(investor, ES, true, nowTs, bytes32(0), expiring);

        bytes memory valid = _sign(registry, nowTs + 1);
        registry.registerIdentityWithAttestation(investor, ES, true, nowTs + 1, bytes32(0), valid);
        assertTrue(registry.isVerified(investor));
        vm.warp(nowTs + 1);
        assertFalse(registry.isVerified(investor));
    }

    /// @dev The malleable twin of a valid signature (s replaced by n - s, v flipped) is rejected by
    ///      OpenZeppelin's ECDSA, which accepts only low-s signatures.
    function test_highSSignature_isRejected() public {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, _digest(registry, expiry));
        bytes32 highS = bytes32(SECP256K1_ORDER - uint256(s));
        uint8 flippedV = v == 27 ? 28 : 27;

        vm.expectRevert(abi.encodeWithSelector(ECDSA.ECDSAInvalidSignatureS.selector, highS));
        registry.registerIdentityWithAttestation(
            investor, ES, true, expiry, bytes32(0), abi.encodePacked(r, highS, flippedV)
        );
    }

    /// @dev EIP-1271 is not supported: with a contract as claim signer, no signature is accepted,
    ///      because the registry only compares the ECDSA-recovered address.
    function test_contractSigner_isNotSupported() public {
        address contractSigner = address(new SignerStub());
        vm.prank(issuer);
        registry.setClaimSigner(contractSigner);

        bytes memory sig = _sign(registry, expiry);
        vm.expectRevert(
            abi.encodeWithSelector(IIdentityRegistry.InvalidAttestationSigner.selector, signer, contractSigner)
        );
        registry.registerIdentityWithAttestation(investor, ES, true, expiry, bytes32(0), sig);
    }
}

/// @notice A contract that would approve any signature under EIP-1271, if the registry asked it.
contract SignerStub {
    function isValidSignature(bytes32, bytes calldata) external pure returns (bytes4) {
        return 0x1626ba7e;
    }
}
