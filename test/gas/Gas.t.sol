// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import {Deploy} from "../../script/Deploy.s.sol";
import {DividendDistributor} from "../../src/compliance/modules/DividendDistributor.sol";
import {MockCurrency} from "../helpers/MockCurrency.sol";

/**
 * @title GasBenchmarks
 * @notice One call per operation against the system `Deploy` produces, for gas measurement only.
 * @dev Not part of the test suite: the default profile excludes `test/gas/`. Run with
 *      `FOUNDRY_PROFILE=gas forge test --isolate --gas-report`, where `--isolate` executes each
 *      top-level call as its own transaction, so cold storage access is priced as it would be
 *      on chain.
 *
 *      `setUp` leaves two verified holders past the lockup, so every measured transfer runs the
 *      full gate against the three rule modules the script registers. The `withDistributor`
 *      benchmarks register the dividend distributor first, so the same operation also pays the
 *      fourth module's hook.
 */
contract GasBenchmarks is Test, Deploy {
    Deployment internal d;

    address internal issuer = address(this);
    address internal agent = makeAddr("agent");
    address internal custodian = makeAddr("custodian");
    address internal alice = makeAddr("alice");
    address internal aliceNew = makeAddr("aliceNew");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    uint16 internal constant ES = 724;
    uint64 internal constant KYC_WINDOW = 3650 days;

    function setUp() public {
        d = _deploy(issuer, agent, custodian);
        bytes32 aliceId = keccak256("investor-alice");
        vm.startPrank(agent);
        d.identityRegistry.registerIdentity(alice, ES, true, uint64(block.timestamp + KYC_WINDOW), aliceId);
        d.identityRegistry.registerIdentity(aliceNew, ES, true, uint64(block.timestamp + KYC_WINDOW), aliceId);
        d.identityRegistry.registerIdentity(bob, ES, true, uint64(block.timestamp + KYC_WINDOW));
        vm.stopPrank();
        d.token.mint(alice, 1_000e18);
        d.token.mint(bob, 1_000e18);
        vm.warp(block.timestamp + LOCKUP_PERIOD + 1);
        vm.prank(alice);
        d.token.approve(bob, type(uint256).max);
    }

    function _attachDistributor() internal returns (DividendDistributor dist) {
        MockCurrency currency = new MockCurrency();
        dist = new DividendDistributor(address(d.compliance), address(d.token), address(currency), issuer);
        d.compliance.addModule(address(dist));
        currency.mint(issuer, 1_000_000e6);
        currency.approve(address(dist), type(uint256).max);
    }

    function test_gas_transfer() public {
        vm.prank(alice);
        d.token.transfer(bob, 1e18);
    }

    function test_gas_transferFrom() public {
        vm.prank(bob);
        d.token.transferFrom(alice, bob, 1e18);
    }

    function test_gas_mintToNewHolder() public {
        vm.prank(agent);
        d.identityRegistry.registerIdentity(carol, ES, true, uint64(block.timestamp + KYC_WINDOW));
        d.token.mint(carol, 1e18);
    }

    function test_gas_burnPartial() public {
        d.token.burn(alice, 1e18);
    }

    function test_gas_forcedRecovery() public {
        vm.prank(custodian);
        d.token.forcedRecovery(alice, aliceNew);
    }

    function test_gas_registerIdentity() public {
        vm.prank(agent);
        d.identityRegistry.registerIdentity(carol, ES, true, uint64(block.timestamp + KYC_WINDOW));
    }

    function test_gas_registerIdentityWithAttestation() public {
        (address signer, uint256 key) = makeAddrAndKey("claimSigner");
        d.identityRegistry.setClaimSigner(signer);
        uint64 expiry = uint64(block.timestamp + 365 days);
        bytes32 structHash = keccak256(
            abi.encode(d.identityRegistry.ATTESTATION_TYPEHASH(), carol, ES, true, expiry, bytes32(0), uint256(0))
        );
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(key, MessageHashUtils.toTypedDataHash(d.identityRegistry.domainSeparator(), structHash));
        d.identityRegistry
            .registerIdentityWithAttestation(carol, ES, true, expiry, bytes32(0), abi.encodePacked(r, s, v));
    }

    function test_gas_withDistributor_transfer() public {
        _attachDistributor();
        vm.prank(alice);
        d.token.transfer(bob, 1e18);
    }

    function test_gas_withDistributor_depositAndClaim() public {
        DividendDistributor dist = _attachDistributor();
        dist.deposit(900e6);
        vm.prank(alice);
        dist.claim(alice);
    }
}
