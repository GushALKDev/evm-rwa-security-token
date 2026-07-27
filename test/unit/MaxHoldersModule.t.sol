// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {MaxHoldersModule} from "../../src/compliance/modules/MaxHoldersModule.sol";
import {IComplianceModule} from "../../src/interfaces/IComplianceModule.sol";
import {Roles} from "../../src/Roles.sol";
import {MockToken} from "../helpers/MockToken.sol";

contract MaxHoldersModuleTest is Test {
    MaxHoldersModule internal module;
    MockToken internal token;

    address internal engine = makeAddr("compliance");
    address internal issuer = makeAddr("issuer");
    address internal agent = makeAddr("agent");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    uint256 internal constant CAP = 3;
    uint256 internal constant AMOUNT = 1_000e18;

    function setUp() public {
        token = new MockToken();
        module = new MaxHoldersModule(engine, address(token), issuer, agent, CAP);
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Mirrors the engine: balance first, then hook.
    function _mint(address to, uint256 amount) internal {
        token.mint(to, amount);
        vm.prank(engine);
        module.moduleCreated(to, amount);
    }

    function _transfer(address from, address to, uint256 amount) internal {
        vm.prank(from);
        token.transfer(to, amount);
        vm.prank(engine);
        module.moduleTransferred(from, to, amount);
    }

    function _burn(address from, uint256 amount) internal {
        token.burn(from, amount);
        vm.prank(engine);
        module.moduleDestroyed(from, amount);
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    function test_constructor_setsState() public view {
        assertEq(module.compliance(), engine);
        assertEq(module.token(), address(token));
        assertEq(module.maxHolders(), CAP);
        assertEq(module.holderCount(), 0);
        assertEq(module.name(), "MaxHoldersModule");
    }

    function test_constructor_revertsOnZeroCap() public {
        vm.expectRevert(MaxHoldersModule.MaxHoldersZero.selector);
        new MaxHoldersModule(engine, address(token), issuer, agent, 0);
    }

    function test_constructor_revertsOnZeroToken() public {
        vm.expectRevert(MaxHoldersModule.ZeroAddress.selector);
        new MaxHoldersModule(engine, address(0), issuer, agent, CAP);
    }

    /*//////////////////////////////////////////////////////////////
                            COUNT TRACKING
    //////////////////////////////////////////////////////////////*/

    function test_mint_incrementsCount() public {
        _mint(alice, AMOUNT);
        assertEq(module.holderCount(), 1);

        _mint(bob, AMOUNT);
        assertEq(module.holderCount(), 2);
    }

    /// @dev Topping up an existing holder does not create a new one.
    function test_mint_toExistingHolderDoesNotIncrement() public {
        _mint(alice, AMOUNT);
        _mint(alice, AMOUNT);

        assertEq(module.holderCount(), 1);
    }

    function test_transfer_toNewHolderIncrements() public {
        _mint(alice, AMOUNT);
        _transfer(alice, bob, AMOUNT / 2);

        assertEq(module.holderCount(), 2);
    }

    /// @dev A full transfer replaces one holder with another: the count is unchanged.
    function test_transfer_fullBalanceKeepsCountFlat() public {
        _mint(alice, AMOUNT);
        assertEq(module.holderCount(), 1);

        _transfer(alice, bob, AMOUNT);

        assertEq(module.holderCount(), 1);
    }

    function test_transfer_betweenExistingHoldersKeepsCountFlat() public {
        _mint(alice, AMOUNT);
        _mint(bob, AMOUNT);

        _transfer(alice, bob, AMOUNT / 2);

        assertEq(module.holderCount(), 2);
    }

    /**
     * @dev A self-transfer moves nothing, so the count must not change. Found by the invariant
     *      suite, which drove `holderCount` above the cap with no new holder in sight.
     *
     *      The hooks infer transitions from post-transfer balances: `balanceOf(to) == amount`
     *      means the recipient came from zero. With `from == to` and a full-balance send that
     *      equality is true while the sender is plainly not empty, so the "joined" and "left"
     *      signals fail to cancel and the count rises for a holder who never appeared. Anyone
     *      could repeat it to exhaust the cap and lock out real investors.
     */
    function test_transfer_selfTransferKeepsCountFlat() public {
        _mint(alice, AMOUNT);

        _transfer(alice, alice, AMOUNT);

        assertEq(token.balanceOf(alice), AMOUNT);
        assertEq(module.holderCount(), 1);
    }

    /// @dev The same for a partial self-transfer, which trips a different branch of the inference.
    function test_transfer_partialSelfTransferKeepsCountFlat() public {
        _mint(alice, AMOUNT);

        _transfer(alice, alice, AMOUNT / 2);

        assertEq(module.holderCount(), 1);
    }

    function test_transfer_senderEmptyingDecrements() public {
        _mint(alice, AMOUNT);
        _mint(bob, AMOUNT);
        assertEq(module.holderCount(), 2);

        _transfer(alice, bob, AMOUNT);

        assertEq(module.holderCount(), 1);
    }

    function test_burn_toZeroDecrements() public {
        _mint(alice, AMOUNT);
        _burn(alice, AMOUNT);

        assertEq(module.holderCount(), 0);
    }

    function test_burn_partialDoesNotDecrement() public {
        _mint(alice, AMOUNT);
        _burn(alice, AMOUNT / 2);

        assertEq(module.holderCount(), 1);
    }

    function test_holderCount_emitsOnChange() public {
        token.mint(alice, AMOUNT);

        vm.expectEmit(false, false, false, true, address(module));
        emit MaxHoldersModule.HolderCountUpdated(1);

        vm.prank(engine);
        module.moduleCreated(alice, AMOUNT);
    }

    /*//////////////////////////////////////////////////////////////
                              ENFORCEMENT
    //////////////////////////////////////////////////////////////*/

    function test_moduleCheck_allowsBelowCap() public {
        _mint(alice, AMOUNT);

        assertTrue(module.moduleCheck(address(0), bob, AMOUNT));
    }

    /// @dev At the cap, a transfer that would create holder number four is refused.
    function test_moduleCheck_blocksNewHolderAtCap() public {
        _mint(alice, AMOUNT);
        _mint(bob, AMOUNT);
        _mint(carol, AMOUNT);
        assertEq(module.holderCount(), CAP);

        assertFalse(module.moduleCheck(address(0), makeAddr("dave"), AMOUNT));
        assertFalse(module.moduleCheck(alice, makeAddr("dave"), AMOUNT / 2));
    }

    /// @dev At the cap, an existing holder can still receive: no new holder appears.
    function test_moduleCheck_allowsExistingHolderAtCap() public {
        _mint(alice, AMOUNT);
        _mint(bob, AMOUNT);
        _mint(carol, AMOUNT);

        assertTrue(module.moduleCheck(alice, bob, AMOUNT / 2));
    }

    /**
     * @dev At the cap, a sender emptying out in the same transfer offsets the new holder, so the
     *      count stays flat and the transfer is allowed. Without this the token would deadlock at
     *      the cap: no holder could ever exit by selling their whole position to a newcomer.
     */
    function test_moduleCheck_allowsReplacementAtCap() public {
        _mint(alice, AMOUNT);
        _mint(bob, AMOUNT);
        _mint(carol, AMOUNT);

        address dave = makeAddr("dave");
        assertTrue(module.moduleCheck(alice, dave, AMOUNT), "full-balance exit must be allowed at cap");

        _transfer(alice, dave, AMOUNT);
        assertEq(module.holderCount(), CAP);
    }

    /// @dev A burn only ever reduces the count.
    function test_moduleCheck_allowsBurn() public {
        _mint(alice, AMOUNT);

        assertTrue(module.moduleCheck(alice, address(0), AMOUNT));
    }

    /*//////////////////////////////////////////////////////////////
                              HOOK ACCESS
    //////////////////////////////////////////////////////////////*/

    /// @dev Negative: an attacker calling hooks directly could desynchronize the count and walk
    ///      past the cap. The gate is what makes the incremental count trustworthy.
    function test_moduleCreated_revertsForNonCompliance() public {
        vm.expectRevert(abi.encodeWithSelector(IComplianceModule.OnlyCompliance.selector, alice, engine));
        vm.prank(alice);
        module.moduleCreated(alice, AMOUNT);
    }

    function test_moduleTransferred_revertsForNonCompliance() public {
        vm.expectRevert(abi.encodeWithSelector(IComplianceModule.OnlyCompliance.selector, alice, engine));
        vm.prank(alice);
        module.moduleTransferred(alice, bob, AMOUNT);
    }

    function test_moduleDestroyed_revertsForNonCompliance() public {
        vm.expectRevert(abi.encodeWithSelector(IComplianceModule.OnlyCompliance.selector, alice, engine));
        vm.prank(alice);
        module.moduleDestroyed(alice, AMOUNT);
    }

    /*//////////////////////////////////////////////////////////////
                              RULE ADMIN
    //////////////////////////////////////////////////////////////*/

    function test_setMaxHolders_updatesAndEmits() public {
        vm.expectEmit(false, false, false, true, address(module));
        emit MaxHoldersModule.MaxHoldersUpdated(10);

        vm.prank(agent);
        module.setMaxHolders(10);

        assertEq(module.maxHolders(), 10);
    }

    /// @dev Negative: the cap is agent-gated.
    function test_setMaxHolders_revertsForNonAgent() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, Roles.AGENT_ROLE)
        );
        vm.prank(alice);
        module.setMaxHolders(10);
    }

    function test_setMaxHolders_revertsOnZero() public {
        vm.expectRevert(MaxHoldersModule.MaxHoldersZero.selector);
        vm.prank(agent);
        module.setMaxHolders(0);
    }

    /// @dev Negative: the cap cannot be set below the live count, which would strand the token in
    ///      an already-illegal state that no transfer could repair.
    function test_setMaxHolders_revertsBelowCurrentCount() public {
        _mint(alice, AMOUNT);
        _mint(bob, AMOUNT);

        vm.expectRevert(abi.encodeWithSelector(MaxHoldersModule.MaxHoldersBelowCurrentCount.selector, 1, 2));
        vm.prank(agent);
        module.setMaxHolders(1);
    }

    function test_setMaxHolders_allowsEqualToCurrentCount() public {
        _mint(alice, AMOUNT);
        _mint(bob, AMOUNT);

        vm.prank(agent);
        module.setMaxHolders(2);

        assertEq(module.maxHolders(), 2);
    }

    /*//////////////////////////////////////////////////////////////
                                  FUZZ
    //////////////////////////////////////////////////////////////*/

    /// @dev Property: the incremental count matches a naive recount over the same population.
    function testFuzz_countMatchesReality(uint8 holders) public {
        uint256 n = bound(holders, 1, 20);

        vm.prank(agent);
        module.setMaxHolders(type(uint256).max);

        for (uint256 i; i < n; ++i) {
            _mint(vm.addr(i + 1000), AMOUNT);
        }
        assertEq(module.holderCount(), n);

        // Empty half of them out and the count must follow exactly.
        uint256 removed;
        for (uint256 i; i < n; i += 2) {
            _burn(vm.addr(i + 1000), AMOUNT);
            ++removed;
        }
        assertEq(module.holderCount(), n - removed);
    }

    /// @dev Property: the count never exceeds the cap when every transfer is gated by the check.
    function testFuzz_countNeverExceedsCap(uint8 attempts) public {
        uint256 n = bound(attempts, 1, 30);

        for (uint256 i; i < n; ++i) {
            address who = vm.addr(i + 2000);
            if (module.moduleCheck(address(0), who, AMOUNT)) {
                _mint(who, AMOUNT);
            }
            assertLe(module.holderCount(), CAP);
        }
    }
}
