// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {LockupModule} from "../../src/compliance/modules/LockupModule.sol";
import {IComplianceModule} from "../../src/interfaces/IComplianceModule.sol";
import {Roles} from "../../src/Roles.sol";
import {MockToken} from "../helpers/MockToken.sol";

contract LockupModuleTest is Test {
    LockupModule internal module;
    MockToken internal token;

    address internal engine = makeAddr("compliance");
    address internal issuer = makeAddr("issuer");
    address internal agent = makeAddr("agent");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal griefer = makeAddr("griefer");

    uint64 internal constant LOCKUP = 365 days;
    uint256 internal constant AMOUNT = 1_000e18;

    function setUp() public {
        vm.warp(1_700_000_000);
        token = new MockToken();
        module = new LockupModule(engine, address(token), issuer, agent, LOCKUP);
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Mirrors the engine: move the balance first, then fire the hook, as the token will.
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
        assertEq(module.lockupPeriod(), LOCKUP);
        assertEq(module.name(), "LockupModule");
        assertTrue(module.hasRole(module.DEFAULT_ADMIN_ROLE(), issuer));
        assertTrue(module.hasRole(Roles.AGENT_ROLE, agent));
    }

    function test_constructor_revertsOnZeroToken() public {
        vm.expectRevert(LockupModule.ZeroAddress.selector);
        new LockupModule(engine, address(0), issuer, agent, LOCKUP);
    }

    function test_constructor_revertsOnZeroCompliance() public {
        vm.expectPartialRevert(IComplianceModule.OnlyCompliance.selector);
        new LockupModule(address(0), address(token), issuer, agent, LOCKUP);
    }

    /*//////////////////////////////////////////////////////////////
                            CLOCK START
    //////////////////////////////////////////////////////////////*/

    /// @dev Mint is the archetypal acquisition and starts the clock.
    function test_mint_startsClock() public {
        // The balance moves first, as it does in the token, so the expectEmit must wrap only the
        // hook call: otherwise it matches the ERC-20 Transfer event instead.
        token.mint(alice, AMOUNT);

        vm.expectEmit(true, false, false, true, address(module));
        emit LockupModule.LockupStarted(alice, uint64(block.timestamp), uint64(block.timestamp) + LOCKUP);

        vm.prank(engine);
        module.moduleCreated(alice, AMOUNT);

        assertEq(module.lockStart(alice), uint64(block.timestamp));
        assertEq(module.unlocksAt(alice), uint64(block.timestamp) + LOCKUP);
    }

    /// @dev An incoming transfer to a fresh wallet also starts the clock.
    function test_transfer_startsClockForNewHolder() public {
        _mint(alice, AMOUNT);
        vm.warp(block.timestamp + LOCKUP);

        uint64 bobStart = uint64(block.timestamp);
        _transfer(alice, bob, AMOUNT);

        assertEq(module.lockStart(bob), bobStart);
    }

    function test_lockStart_isZeroForUnknownInvestor() public view {
        assertEq(module.lockStart(alice), 0);
        assertEq(module.unlocksAt(alice), 0);
    }

    /*//////////////////////////////////////////////////////////////
                            ENFORCEMENT
    //////////////////////////////////////////////////////////////*/

    function test_moduleCheck_blocksBeforeExpiry() public {
        _mint(alice, AMOUNT);

        assertFalse(module.moduleCheck(alice, bob, AMOUNT));
    }

    function test_moduleCheck_blocksOneSecondBeforeExpiry() public {
        _mint(alice, AMOUNT);
        vm.warp(block.timestamp + LOCKUP - 1);

        assertFalse(module.moduleCheck(alice, bob, AMOUNT));
    }

    /// @dev Released exactly at expiry: the boundary is inclusive.
    function test_moduleCheck_allowsExactlyAtExpiry() public {
        _mint(alice, AMOUNT);
        vm.warp(block.timestamp + LOCKUP);

        assertTrue(module.moduleCheck(alice, bob, AMOUNT));
    }

    function test_moduleCheck_allowsAfterExpiry() public {
        _mint(alice, AMOUNT);
        vm.warp(block.timestamp + LOCKUP + 1 days);

        assertTrue(module.moduleCheck(alice, bob, AMOUNT));
    }

    /// @dev A mint has no sender to restrain.
    function test_moduleCheck_allowsMint() public view {
        assertTrue(module.moduleCheck(address(0), alice, AMOUNT));
    }

    /// @dev An address with no clock was never an investor, so the rule has nothing to say.
    function test_moduleCheck_allowsSenderWithNoClock() public view {
        assertTrue(module.moduleCheck(alice, bob, AMOUNT));
    }

    /*//////////////////////////////////////////////////////////////
                    ANTI-GRIEFING (MODEL 2 PROPERTY)
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev The property model 2 exists for. A griefer sends 1 wei just before Alice's lockup
     *      expires. Under a per-acquisition model this would restart her clock and lock her
     *      position for another full year, for the price of one dust transfer. It must not.
     */
    function test_griefing_oneWeiCannotRelockPosition() public {
        _mint(alice, AMOUNT);
        uint64 originalStart = module.lockStart(alice);

        // The griefer acquires a position and waits out their own lockup.
        _mint(griefer, 1);
        vm.warp(block.timestamp + LOCKUP);

        // Alice is free at this point.
        assertTrue(module.moduleCheck(alice, bob, AMOUNT));

        // The griefer dusts her.
        _transfer(griefer, alice, 1);

        assertEq(module.lockStart(alice), originalStart, "dust transfer must not move the clock");
        assertTrue(module.moduleCheck(alice, bob, AMOUNT), "alice must stay free");
    }

    /// @dev The general form: no subsequent receipt resets an existing clock.
    function test_subsequentReceiptDoesNotResetClock() public {
        _mint(alice, AMOUNT);
        uint64 originalStart = module.lockStart(alice);

        vm.warp(block.timestamp + 180 days);
        _mint(alice, AMOUNT);

        assertEq(module.lockStart(alice), originalStart);

        // Still released on the ORIGINAL schedule, not a restarted one.
        vm.warp(uint256(originalStart) + LOCKUP);
        assertTrue(module.moduleCheck(alice, bob, AMOUNT));
    }

    /*//////////////////////////////////////////////////////////////
                            CLOCK CLEARING
    //////////////////////////////////////////////////////////////*/

    /// @dev Exiting to zero clears the clock, so a later re-entry is locked afresh.
    function test_exitToZero_clearsClockAndRelocksOnReentry() public {
        _mint(alice, AMOUNT);
        vm.warp(block.timestamp + LOCKUP);

        vm.prank(alice);
        token.transfer(bob, AMOUNT);

        vm.expectEmit(true, false, false, false, address(module));
        emit LockupModule.LockupCleared(alice);

        vm.prank(engine);
        module.moduleTransferred(alice, bob, AMOUNT);

        assertEq(module.lockStart(alice), 0);

        // Re-entry starts a fresh clock: without clearing, Alice would keep her expired one and
        // never be locked again.
        _mint(alice, AMOUNT);
        assertEq(module.lockStart(alice), uint64(block.timestamp));
        assertFalse(module.moduleCheck(alice, bob, AMOUNT));
    }

    function test_partialTransfer_doesNotClearClock() public {
        _mint(alice, AMOUNT);
        uint64 start = module.lockStart(alice);
        vm.warp(block.timestamp + LOCKUP);

        _transfer(alice, bob, AMOUNT / 2);

        assertEq(module.lockStart(alice), start);
    }

    function test_burnToZero_clearsClock() public {
        _mint(alice, AMOUNT);
        _burn(alice, AMOUNT);

        assertEq(module.lockStart(alice), 0);
    }

    function test_partialBurn_doesNotClearClock() public {
        _mint(alice, AMOUNT);
        uint64 start = module.lockStart(alice);

        _burn(alice, AMOUNT / 2);

        assertEq(module.lockStart(alice), start);
    }

    /*//////////////////////////////////////////////////////////////
                              HOOK ACCESS
    //////////////////////////////////////////////////////////////*/

    /// @dev Negative: hooks are callable only by the bound engine. Otherwise anyone could
    ///      desynchronize the module's clocks from reality.
    function test_moduleTransferred_revertsForNonCompliance() public {
        vm.expectRevert(abi.encodeWithSelector(IComplianceModule.OnlyCompliance.selector, alice, engine));
        vm.prank(alice);
        module.moduleTransferred(alice, bob, AMOUNT);
    }

    function test_moduleCreated_revertsForNonCompliance() public {
        vm.expectRevert(abi.encodeWithSelector(IComplianceModule.OnlyCompliance.selector, alice, engine));
        vm.prank(alice);
        module.moduleCreated(alice, AMOUNT);
    }

    function test_moduleDestroyed_revertsForNonCompliance() public {
        vm.expectRevert(abi.encodeWithSelector(IComplianceModule.OnlyCompliance.selector, alice, engine));
        vm.prank(alice);
        module.moduleDestroyed(alice, AMOUNT);
    }

    /// @dev Negative: not even the issuer can call a hook. The engine is the only caller.
    function test_hooks_revertForIssuer() public {
        vm.expectRevert(abi.encodeWithSelector(IComplianceModule.OnlyCompliance.selector, issuer, engine));
        vm.prank(issuer);
        module.moduleCreated(alice, AMOUNT);
    }

    /*//////////////////////////////////////////////////////////////
                              RULE ADMIN
    //////////////////////////////////////////////////////////////*/

    function test_setLockupPeriod_updatesAndEmits() public {
        vm.expectEmit(false, false, false, true, address(module));
        emit LockupModule.LockupPeriodUpdated(30 days);

        vm.prank(agent);
        module.setLockupPeriod(30 days);

        assertEq(module.lockupPeriod(), 30 days);
    }

    /// @dev Negative: setting the period is agent-gated.
    function test_setLockupPeriod_revertsForNonAgent() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, Roles.AGENT_ROLE)
        );
        vm.prank(alice);
        module.setLockupPeriod(30 days);
    }

    /// @dev A zero period disables the rule outright.
    function test_zeroPeriod_disablesRule() public {
        vm.prank(agent);
        module.setLockupPeriod(0);

        _mint(alice, AMOUNT);

        assertTrue(module.moduleCheck(alice, bob, AMOUNT));
    }

    /// @dev Changing the period applies to running clocks, which is the documented tradeoff.
    function test_shorteningPeriod_releasesExistingHolderEarly() public {
        _mint(alice, AMOUNT);
        assertFalse(module.moduleCheck(alice, bob, AMOUNT));

        vm.warp(block.timestamp + 30 days);

        vm.prank(agent);
        module.setLockupPeriod(30 days);

        assertTrue(module.moduleCheck(alice, bob, AMOUNT));
    }

    /*//////////////////////////////////////////////////////////////
                                  FUZZ
    //////////////////////////////////////////////////////////////*/

    /// @dev Property: the check tracks the unlock boundary exactly, at any point in time.
    function testFuzz_moduleCheck_tracksBoundary(uint64 period, uint64 elapsed) public {
        period = uint64(bound(period, 1, 3650 days));
        elapsed = uint64(bound(elapsed, 0, 7300 days));

        vm.prank(agent);
        module.setLockupPeriod(period);

        uint64 start = uint64(block.timestamp);
        _mint(alice, AMOUNT);

        vm.warp(uint256(start) + elapsed);
        assertEq(module.moduleCheck(alice, bob, AMOUNT), elapsed >= period);
    }

    /// @dev Property: no receipt of any size, at any time, ever moves an existing clock.
    function testFuzz_incomingTransferNeverResetsClock(uint256 dust, uint64 delay) public {
        dust = bound(dust, 1, AMOUNT);
        delay = uint64(bound(delay, 0, 3650 days));

        _mint(alice, AMOUNT);
        uint64 originalStart = module.lockStart(alice);

        _mint(griefer, dust);
        vm.warp(block.timestamp + delay);
        _transfer(griefer, alice, dust);

        assertEq(module.lockStart(alice), originalStart);
    }
}
