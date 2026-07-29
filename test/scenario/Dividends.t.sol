// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {Deploy} from "../../script/Deploy.s.sol";
import {DividendDistributor} from "../../src/compliance/modules/DividendDistributor.sol";
import {Roles} from "../../src/Roles.sol";
import {MockCurrency} from "../helpers/MockCurrency.sol";

/**
 * @title DividendsTest
 * @notice End-to-end income distribution over the fully wired system.
 * @dev The unit suite drives the distributor's hooks from a mocked engine address, which proves
 *      the accumulator arithmetic but not the integration. These tests prove the claim the design
 *      rests on: that income distribution is reachable purely as a compliance module, with the
 *      real engine fanning out the real token's hooks and `SecurityToken` unmodified.
 *
 *      The distributor is registered with `addModule` after `_deploy` has already closed the
 *      graph, which is itself the point: a new capability is added to a live system without
 *      redeploying or touching the token.
 */
contract DividendsTest is Test, Deploy {
    Deployment internal d;
    DividendDistributor internal dist;
    MockCurrency internal currency;

    address internal issuer = address(this);
    address internal agent = makeAddr("agent");
    address internal custodian = makeAddr("custodian");

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    uint16 internal constant ES = 724;
    uint64 internal constant KYC_WINDOW = 10 * 365 days;
    uint256 internal constant AMOUNT = 1_000e18;
    uint256 internal constant INCOME = 900e6;

    function setUp() public {
        d = _deploy(issuer, agent, custodian);

        currency = new MockCurrency();
        dist = new DividendDistributor(address(d.compliance), address(d.token), address(currency), issuer);
        d.compliance.addModule(address(dist));

        currency.mint(issuer, 1_000_000e6);
        currency.approve(address(dist), type(uint256).max);
    }

    function _onboard(address who) internal {
        vm.prank(agent);
        d.identityRegistry.registerIdentity(who, ES, true, uint64(block.timestamp + KYC_WINDOW));
    }

    function _onboardAs(address who, bytes32 id) internal {
        vm.prank(agent);
        d.identityRegistry.registerIdentity(who, ES, true, uint64(block.timestamp + KYC_WINDOW), id);
    }

    /*//////////////////////////////////////////////////////////////
                        INCOME OVER A REAL TRANSFER
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev The full income cycle: subscribe, receive income, sell after the lockup, and see the
     *      entitlement split at the moment of sale rather than at the moment of claiming.
     */
    function test_scenario_incomeAccruesToTheHolderAtTheTimeOfDeposit() public {
        _onboard(alice);
        _onboard(bob);

        d.token.mint(alice, AMOUNT);
        dist.deposit(INCOME);

        // Alice held the whole supply when the income landed, so all of it is hers.
        assertEq(dist.claimable(alice), INCOME - 1, "sole holder takes the deposit less dust");
        assertEq(dist.claimable(bob), 0);

        // She sells the position on once the lockup allows it. The income already earned does not
        // travel with the shares: this is the correction term doing its job through the real hook.
        vm.warp(block.timestamp + LOCKUP_PERIOD + 1);
        vm.prank(alice);
        d.token.transfer(bob, AMOUNT);

        assertEq(dist.claimable(alice), INCOME - 1, "seller kept the income earned while holding");
        assertEq(dist.claimable(bob), 0, "buyer was not paid for income predating them");

        // The next distribution goes entirely to the new holder.
        dist.deposit(INCOME);
        assertEq(dist.claimable(bob), INCOME, "buyer earns everything from here");

        vm.prank(alice);
        dist.claim(alice);
        vm.prank(bob);
        dist.claim(bob);

        assertEq(currency.balanceOf(alice) + currency.balanceOf(bob), INCOME * 2 - 1);
    }

    /**
     * @dev A forced recovery must carry unclaimed income to the new wallet along with the balance.
     *      Recovery relocates a position whole, and the distributor learns about it only because
     *      the token fires the transfer hook on the recovery path too.
     */
    function test_scenario_recoveryCarriesUnclaimedIncome() public {
        bytes32 investor = keccak256("alice-investor");
        _onboardAs(alice, investor);
        _onboardAs(bob, investor);

        d.token.mint(alice, AMOUNT);
        dist.deposit(INCOME);

        uint256 owed = dist.claimable(alice);
        assertGt(owed, 0);

        vm.prank(custodian);
        d.token.forcedRecovery(alice, bob);

        assertEq(dist.claimable(alice), 0, "the lost wallet keeps nothing");
        assertEq(dist.claimable(bob), owed, "the income followed the position");

        vm.prank(bob);
        dist.claim(bob);
        assertEq(currency.balanceOf(bob), owed);
    }

    /**
     * @dev The distributor must not become a transfer restriction. Registering it adds accounting
     *      to the engine, and a transfer that the compliance rules allow must still be allowed.
     */
    function test_scenario_distributorDoesNotGateTransfers() public {
        _onboard(alice);
        _onboard(bob);

        d.token.mint(alice, AMOUNT);
        dist.deposit(INCOME);

        vm.warp(block.timestamp + LOCKUP_PERIOD + 1);
        assertTrue(d.token.canTransfer(alice, bob, AMOUNT), "the distributor blocked a valid transfer");

        vm.prank(alice);
        d.token.transfer(bob, AMOUNT);
        assertEq(d.token.balanceOf(bob), AMOUNT);
    }

    /**
     * @dev Income is distributed across a real holder set, and the sum paid out never exceeds the
     *      sum deposited even though each holder's share truncates independently.
     */
    function test_scenario_multiHolderDistributionStaysSolvent() public {
        _onboard(alice);
        _onboard(bob);

        d.token.mint(alice, AMOUNT);
        d.token.mint(bob, AMOUNT / 3);

        for (uint256 i = 0; i < 5; ++i) {
            dist.deposit(INCOME);
        }

        uint256 owed = dist.claimable(alice) + dist.claimable(bob);
        assertLe(owed, INCOME * 5, "distributed more than was deposited");
        assertLe(owed, currency.balanceOf(address(dist)), "cannot cover what is owed");

        vm.prank(alice);
        dist.claim(alice);
        vm.prank(bob);
        dist.claim(bob);
    }
}
