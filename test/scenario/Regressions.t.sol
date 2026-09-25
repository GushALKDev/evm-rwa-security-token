// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {Deploy} from "../../script/Deploy.s.sol";
import {ISecurityToken} from "../../src/interfaces/ISecurityToken.sol";

/**
 * @title RegressionsTest
 * @notice One test per bug found in the review rounds, run against the system `Deploy` produces.
 * @dev Each test asserts the correct behaviour and failed against the code before its fix. The
 *      README "Review notes" section maps every test here to its finding and its fix commit.
 */
contract RegressionsTest is Test, Deploy {
    Deployment internal d;

    address internal issuer = address(this);
    address internal agent = makeAddr("agent");
    address internal custodian = makeAddr("custodian");

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal dave = makeAddr("dave");
    address internal stranger = makeAddr("stranger");

    uint16 internal constant ES = 724;
    uint64 internal constant KYC_WINDOW = 10 * 365 days;
    uint256 internal constant AMOUNT = 1_000e18;

    function setUp() public {
        d = _deploy(issuer, agent, custodian);
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _onboard(address who) internal {
        vm.prank(agent);
        d.identityRegistry.registerIdentity(who, ES, true, uint64(block.timestamp + KYC_WINDOW));
    }

    function _onboardAs(address who, bytes32 id) internal {
        vm.prank(agent);
        d.identityRegistry.registerIdentity(who, ES, true, uint64(block.timestamp + KYC_WINDOW), id);
    }

    function _liveHolders(address[4] memory wallets) internal view returns (uint256 live) {
        for (uint256 i; i < wallets.length; ++i) {
            if (d.token.balanceOf(wallets[i]) != 0) ++live;
        }
    }

    /*//////////////////////////////////////////////////////////////
                  ZERO AMOUNTS DO NOT MOVE THE HOLDER COUNT
    //////////////////////////////////////////////////////////////*/

    /// @dev A verified wallet holding nothing sends zero tokens. No holder joins or leaves, so the
    ///      count must not move, and the cap must keep refusing a third holder.
    function test_zeroAmountTransfer_doesNotDeflateHolderCount() public {
        _onboard(alice);
        _onboard(bob);
        _onboard(carol);
        d.token.mint(alice, AMOUNT);
        d.token.mint(bob, AMOUNT);
        vm.prank(agent);
        d.maxHolders.setMaxHolders(2);

        vm.prank(carol);
        d.token.transfer(alice, 0);
        vm.prank(carol);
        d.token.transfer(alice, 0);

        assertEq(d.maxHolders.holderCount(), 2, "zero-amount sends moved the count");
        vm.expectRevert(abi.encodeWithSelector(ISecurityToken.ComplianceCheckFailed.selector, address(0), carol, 1));
        d.token.mint(carol, 1);
        assertEq(_liveHolders([alice, bob, carol, dave]), 2);
    }

    /// @dev `transferFrom` with a zero amount needs no allowance, so any address can drive the
    ///      zero-amount path on behalf of an empty verified wallet. The count must still not move.
    function test_zeroAmountTransferFromByStranger_doesNotDeflateHolderCount() public {
        _onboard(alice);
        _onboard(carol);
        d.token.mint(alice, AMOUNT);

        vm.prank(stranger);
        d.token.transferFrom(carol, alice, 0);

        assertEq(d.maxHolders.holderCount(), 1);
    }

    /// @dev An issuer burn of zero from a wallet that holds nothing removes no holder.
    function test_zeroBurnFromNonHolder_doesNotDeflateHolderCount() public {
        _onboard(alice);
        d.token.mint(alice, AMOUNT);

        d.token.burn(carol, 0);

        assertEq(d.maxHolders.holderCount(), 1);
    }

    /// @dev The consequence of a deflated count: a legitimate full exit to an existing holder
    ///      underflowed and reverted. With the count intact the exit settles.
    function test_zeroAmountSends_doNotBlockLaterExits() public {
        _onboard(alice);
        _onboard(bob);
        _onboard(carol);
        d.token.mint(alice, AMOUNT);
        d.token.mint(bob, AMOUNT);

        vm.startPrank(stranger);
        d.token.transferFrom(carol, alice, 0);
        d.token.transferFrom(carol, alice, 0);
        d.token.transferFrom(carol, alice, 0);
        vm.stopPrank();

        vm.warp(block.timestamp + LOCKUP_PERIOD + 1);
        vm.prank(alice);
        d.token.transfer(bob, AMOUNT);

        assertEq(d.maxHolders.holderCount(), 1);
        assertEq(_liveHolders([alice, bob, carol, dave]), 1);
    }
}
