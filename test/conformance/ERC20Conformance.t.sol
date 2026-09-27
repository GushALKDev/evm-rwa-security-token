// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

import {Deploy} from "../../script/Deploy.s.sol";
import {ISecurityToken} from "../../src/interfaces/ISecurityToken.sol";

/**
 * @title ERC20ConformanceTest
 * @notice Checks the permissioned token against the ERC-20 interface and events.
 * @dev Where the token differs from a plain ERC-20 by design, the test asserts the actual
 *      behaviour and says so. The one systematic difference: a transfer the compliance gate
 *      refuses reverts with a custom error instead of returning false. ERC-20 allows either
 *      ("SHOULD throw"), and every refusal is covered by the unit suites; here the gate is
 *      satisfied so the ERC-20 behaviour itself is visible.
 */
contract ERC20ConformanceTest is Test, Deploy {
    Deployment internal d;

    address internal issuer = address(this);
    address internal agent = makeAddr("agent");
    address internal custodian = makeAddr("custodian");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal spender = makeAddr("spender");

    uint256 internal constant AMOUNT = 1_000e18;

    function setUp() public {
        d = _deploy(issuer, agent, custodian);
        vm.startPrank(agent);
        d.identityRegistry.registerIdentity(alice, 724, true, uint64(block.timestamp + 3650 days));
        d.identityRegistry.registerIdentity(bob, 724, true, uint64(block.timestamp + 3650 days));
        vm.stopPrank();
        d.token.mint(alice, AMOUNT);
        vm.warp(block.timestamp + LOCKUP_PERIOD + 1);
    }

    /*//////////////////////////////////////////////////////////////
                                METADATA
    //////////////////////////////////////////////////////////////*/

    function test_metadata() public view {
        assertEq(d.token.name(), TOKEN_NAME);
        assertEq(d.token.symbol(), TOKEN_SYMBOL);
        assertEq(d.token.decimals(), 18);
        assertEq(d.token.totalSupply(), AMOUNT);
    }

    /*//////////////////////////////////////////////////////////////
                         TRANSFER AND APPROVAL
    //////////////////////////////////////////////////////////////*/

    /// @dev `transfer` returns true and emits Transfer(from, to, value).
    function test_transfer_returnsTrueAndEmits() public {
        vm.expectEmit(true, true, false, true, address(d.token));
        emit IERC20.Transfer(alice, bob, 10e18);
        vm.prank(alice);
        assertTrue(d.token.transfer(bob, 10e18));
        assertEq(d.token.balanceOf(bob), 10e18);
    }

    /// @dev `approve` returns true, emits Approval, and overwrites rather than adds.
    function test_approve_returnsTrueEmitsAndOverwrites() public {
        vm.expectEmit(true, true, false, true, address(d.token));
        emit IERC20.Approval(alice, spender, 50e18);
        vm.prank(alice);
        assertTrue(d.token.approve(spender, 50e18));

        vm.prank(alice);
        d.token.approve(spender, 20e18);
        assertEq(d.token.allowance(alice, spender), 20e18);
    }

    /// @dev `transferFrom` returns true, emits Transfer, and consumes the allowance. OpenZeppelin
    ///      v5 does not emit Approval when an allowance is spent; ERC-20 does not require it.
    function test_transferFrom_returnsTrueConsumesAllowanceAndEmitsTransferOnly() public {
        vm.prank(alice);
        d.token.approve(spender, 50e18);

        vm.recordLogs();
        vm.prank(spender);
        assertTrue(d.token.transferFrom(alice, bob, 30e18));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(d.token.allowance(alice, spender), 20e18);
        uint256 approvals;
        uint256 transfers;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(d.token)) continue;
            if (logs[i].topics[0] == IERC20.Approval.selector) ++approvals;
            if (logs[i].topics[0] == IERC20.Transfer.selector) ++transfers;
        }
        assertEq(transfers, 1);
        assertEq(approvals, 0, "OZ v5 spends an allowance without an Approval event");
    }

    /// @dev An allowance of type(uint256).max is never decreased (OpenZeppelin v5 behaviour).
    function test_transferFrom_unlimitedAllowanceIsNotConsumed() public {
        vm.prank(alice);
        d.token.approve(spender, type(uint256).max);
        vm.prank(spender);
        d.token.transferFrom(alice, bob, 30e18);
        assertEq(d.token.allowance(alice, spender), type(uint256).max);
    }

    /// @dev Spending beyond the allowance reverts with the OpenZeppelin v5 error.
    function test_transferFrom_beyondAllowanceReverts() public {
        vm.prank(alice);
        d.token.approve(spender, 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 1, 2));
        vm.prank(spender);
        d.token.transferFrom(alice, bob, 2);
    }

    /// @dev Approving the zero address, or approving from it, reverts.
    function test_approve_zeroAddressReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        vm.prank(alice);
        d.token.approve(address(0), 1);

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidApprover.selector, address(0)));
        vm.prank(address(0));
        d.token.approve(spender, 1);
    }

    /// @dev A transfer to the zero address reverts before the compliance gate runs; burning is the
    ///      issuer's `burn`, not a transfer to zero.
    function test_transfer_toZeroAddressReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(alice);
        d.token.transfer(address(0), 1);
    }

    /*//////////////////////////////////////////////////////////////
                             EDGE AMOUNTS
    //////////////////////////////////////////////////////////////*/

    /// @dev ERC-20: "Transfers of 0 values MUST be treated as normal transfers and fire the
    ///      Transfer event." Both transfer and transferFrom do, within the token-level checks.
    function test_zeroAmountTransfers_areNormalTransfers() public {
        vm.expectEmit(true, true, false, true, address(d.token));
        emit IERC20.Transfer(alice, bob, 0);
        vm.prank(alice);
        assertTrue(d.token.transfer(bob, 0));

        vm.expectEmit(true, true, false, true, address(d.token));
        emit IERC20.Transfer(alice, bob, 0);
        vm.prank(spender);
        assertTrue(d.token.transferFrom(alice, bob, 0));
    }

    /// @dev A self-transfer succeeds, leaves the balance unchanged and fires Transfer(a, a, v).
    function test_selfTransfer() public {
        vm.expectEmit(true, true, false, true, address(d.token));
        emit IERC20.Transfer(alice, alice, 10e18);
        vm.prank(alice);
        assertTrue(d.token.transfer(alice, 10e18));
        assertEq(d.token.balanceOf(alice), AMOUNT);
    }

    /*//////////////////////////////////////////////////////////////
                            MINT AND BURN
    //////////////////////////////////////////////////////////////*/

    /// @dev Mint and burn emit Transfer from and to the zero address, as ERC-20 recommends for
    ///      token creation and destruction.
    function test_mintAndBurn_emitTransferFromAndToZero() public {
        vm.expectEmit(true, true, false, true, address(d.token));
        emit IERC20.Transfer(address(0), bob, 5e18);
        d.token.mint(bob, 5e18);

        vm.expectEmit(true, true, false, true, address(d.token));
        emit IERC20.Transfer(bob, address(0), 2e18);
        d.token.burn(bob, 2e18);

        assertEq(d.token.totalSupply(), AMOUNT + 3e18);
    }

    /// @dev Difference by design: a transfer the gate refuses reverts rather than returning
    ///      false. Shown for an unverified recipient.
    function test_refusedTransfer_revertsInsteadOfReturningFalse() public {
        address stranger = makeAddr("stranger");
        vm.expectRevert(abi.encodeWithSelector(ISecurityToken.RecipientNotVerified.selector, stranger));
        vm.prank(alice);
        d.token.transfer(stranger, 1);
    }
}
