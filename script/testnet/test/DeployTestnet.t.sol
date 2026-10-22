// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {Deploy} from "../../Deploy.s.sol";
import {DeployTestnet} from "../DeployTestnet.s.sol";
import {TestnetDesk} from "../TestnetDesk.sol";
import {TestnetEURC} from "../TestnetEURC.sol";
import {DividendDistributor} from "../../../src/compliance/modules/DividendDistributor.sol";
import {LockupModule} from "../../../src/compliance/modules/LockupModule.sol";
import {ISecurityToken} from "../../../src/interfaces/ISecurityToken.sol";
import {Roles} from "../../../src/Roles.sol";

/**
 * @title DeployTestnetTest
 * @notice Rehearses DeployTestnet.s.sol, then drives the deployment the way the demo app does and
 *         the way a stranger on a shared deployment might.
 * @dev Run with FOUNDRY_PROFILE=testnet. The protocol has no external dependency, so the rehearsal
 *      needs no mocks. Outside a broadcast the script writes no file.
 *
 *      The app-flow tests build every call exactly as the app does: `onboard(country)`,
 *      `claimNotes()`, `transfer(to, amount)` on the token, `payCoupon()` and `claim(account)` with
 *      the connected account as the recipient.
 */
contract DeployTestnetTest is Test {
    uint16 internal constant SPAIN = 724;
    uint16 internal constant IRAN = 364;
    uint256 internal constant NOTES = 10e18;

    address internal visitor = makeAddr("visitor");
    address internal other = makeAddr("other visitor");
    address internal griefer = makeAddr("griefer");

    DeployTestnet internal script;
    Deploy.Deployment internal d;
    TestnetDesk internal desk;
    DividendDistributor internal distributor;
    TestnetEURC internal eurc;
    DeployTestnet.Seeds internal seeds;
    uint256 internal deployedAt;

    function setUp() public {
        vm.warp(1_800_000_000);
        deployedAt = block.timestamp;
        script = new DeployTestnet();
        d = script.run();
        (distributor, desk, eurc,) = script.demo();
        seeds = script.seeds();
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Onboarding plus the first claim, as a visitor does it from the app's desk dialog.
    function _join(address who, uint16 country) internal {
        vm.startPrank(who);
        desk.onboard(country);
        desk.claimNotes();
        vm.stopPrank();
    }

    function _transfer(address from, address to, uint256 amount) internal {
        vm.prank(from);
        assertTrue(d.token.transfer(to, amount), "transfer");
    }

    /*//////////////////////////////////////////////////////////////
                               REHEARSAL
    //////////////////////////////////////////////////////////////*/

    function test_run_keepsTheDeployParametersAndAttachesTheDistributorLast() public view {
        assertEq(d.maxHolders.maxHolders(), 499, "Deploy.s.sol holder cap");
        assertEq(d.token.name(), "Real Estate Note Token", "name");
        assertEq(d.token.symbol(), "RENT", "symbol");
        (, bytes32 anchored,) = d.documentRegistry.getDocument(bytes32("TERMS"));
        assertEq(anchored, 0xc47a09b676c0dc0d2575c4dd2240d665048c0bb3fec1ba7b3c0eab1b1c49aac9, "terms anchored");

        address[] memory modules = d.compliance.modules();
        assertEq(modules.length, 4, "four modules");
        assertEq(modules[0], address(d.maxHolders), "holder cap first");
        assertEq(modules[1], address(d.countryRestriction), "country rule second");
        assertEq(modules[2], address(d.lockup), "lockup third");
        assertEq(modules[3], address(distributor), "distributor last");
        assertEq(address(distributor.currency()), address(eurc), "pays in testnet EURC");
    }

    /// @dev The module is built with Deploy.s.sol's 365 days, then shortened through its own setter:
    ///      no constructor parameter of the protocol deployment changes.
    function test_run_shortensTheLockupThroughTheModuleSetter() public {
        vm.recordLogs();
        DeployTestnet fresh = new DeployTestnet();
        Deploy.Deployment memory e = fresh.run();

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = LockupModule.LockupPeriodUpdated.selector;
        uint64[] memory periods = new uint64[](2);
        uint256 n;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(e.lockup) && logs[i].topics[0] == topic) {
                periods[n++] = abi.decode(logs[i].data, (uint64));
            }
        }
        assertEq(n, 2, "constructor, then setter");
        assertEq(periods[0], 365 days, "built with Deploy.s.sol's period");
        assertEq(periods[1], 5 minutes, "then shortened");
        assertEq(e.lockup.lockupPeriod(), 5 minutes, "in force");
    }

    /// @dev The desk holds exactly the three roles its three functions need, and none of the
    ///      operator powers (pause, freeze, recovery, rule parameters).
    function test_run_givesTheDeskItsThreeRolesAndNoOther() public view {
        address a = address(desk);
        bytes32 admin = d.token.DEFAULT_ADMIN_ROLE();
        assertTrue(d.identityRegistry.hasRole(Roles.AGENT_ROLE, a), "registers its caller");
        assertTrue(d.token.hasRole(admin, a), "mints to its caller");
        assertTrue(distributor.hasRole(Roles.AGENT_ROLE, a), "deposits coupons");

        assertFalse(d.token.hasRole(Roles.AGENT_ROLE, a), "no pause or freeze");
        assertFalse(d.token.hasRole(Roles.CUSTODIAN_ROLE, a), "no recovery");
        assertFalse(d.identityRegistry.hasRole(admin, a), "no claim signer changes");
        assertFalse(d.compliance.hasRole(admin, a), "no module changes");
        assertFalse(d.maxHolders.hasRole(Roles.AGENT_ROLE, a), "no cap changes");
        assertFalse(d.lockup.hasRole(Roles.AGENT_ROLE, a), "no lockup changes");
        assertFalse(d.countryRestriction.hasRole(Roles.AGENT_ROLE, a), "no country changes");
        assertFalse(distributor.hasRole(admin, a), "no distributor admin");
    }

    function test_run_seedsAThousandNotesAndPaysTheFirstCoupon() public view {
        assertEq(d.token.totalSupply(), 1_000e18, "seeded supply");
        assertEq(d.maxHolders.holderCount(), 5, "five seeded holders");
        assertEq(eurc.balanceOf(address(distributor)), 5_000e6, "first coupon: 5 EURC per note");
        assertEq(desk.nextCouponAt(), deployedAt + 10 minutes, "next coupon in ten minutes");
        assertTrue(d.countryRestriction.isRestricted(408), "North Korea restricted");
        assertTrue(d.countryRestriction.isRestricted(IRAN), "Iran restricted");
    }

    /// @dev Each seed exists to show one outcome of the gate. Checked by the revert the token itself
    ///      raises, once the seeded lockups have run out.
    function test_run_seedsOneWalletPerGateOutcome() public {
        vm.warp(deployedAt + 5 minutes);
        vm.prank(visitor);
        desk.onboard(SPAIN);

        // Settled: passes every check.
        assertTrue(d.token.canTransfer(seeds.settled, visitor, 1e18), "settled passes");

        // Partly frozen: 150 of 250 notes are free.
        vm.prank(seeds.partlyFrozen);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISecurityToken.InsufficientUnfrozenBalance.selector, seeds.partlyFrozen, 150e18, 151e18
            )
        );
        d.token.transfer(visitor, 151e18);
        _transfer(seeds.partlyFrozen, visitor, 150e18);

        // Frozen: neither sends nor receives.
        vm.prank(seeds.frozen);
        vm.expectRevert(abi.encodeWithSelector(ISecurityToken.SenderAddressFrozen.selector, seeds.frozen));
        d.token.transfer(visitor, 1);
        vm.prank(seeds.settled);
        vm.expectRevert(abi.encodeWithSelector(ISecurityToken.RecipientAddressFrozen.selector, seeds.frozen));
        d.token.transfer(seeds.frozen, 1);

        // Suspended: the identity was removed, the balance kept.
        assertEq(d.token.balanceOf(seeds.suspended), 100e18, "balance survives removal");
        vm.prank(seeds.suspended);
        vm.expectRevert(abi.encodeWithSelector(ISecurityToken.SenderNotVerified.selector, seeds.suspended));
        d.token.transfer(visitor, 1);

        // Restricted country: verified, and rejected by the country rule.
        assertTrue(d.identityRegistry.isVerified(seeds.restricted), "restricted investor is verified");
        vm.prank(seeds.settled);
        vm.expectRevert(
            abi.encodeWithSelector(ISecurityToken.ComplianceCheckFailed.selector, seeds.settled, seeds.restricted, 1)
        );
        d.token.transfer(seeds.restricted, 1);
        assertFalse(d.countryRestriction.moduleCheck(seeds.settled, seeds.restricted, 1), "the country rule rejects");

        // Unverified: never registered.
        vm.prank(seeds.settled);
        vm.expectRevert(abi.encodeWithSelector(ISecurityToken.RecipientNotVerified.selector, seeds.unverified));
        d.token.transfer(seeds.unverified, 1);
    }

    function test_run_theLapsedAttestationStopsItsHolderAfterAnHour() public {
        vm.warp(deployedAt + 1 hours - 1);
        assertTrue(d.identityRegistry.isVerified(seeds.lapsed), "still verified");
        vm.warp(deployedAt + 1 hours);
        assertFalse(d.identityRegistry.isVerified(seeds.lapsed), "lapsed");
        vm.prank(seeds.lapsed);
        vm.expectRevert(abi.encodeWithSelector(ISecurityToken.SenderNotVerified.selector, seeds.lapsed));
        d.token.transfer(seeds.settled, 1);
    }

    /// @dev Outside a broadcast (a dry run, or any test) the deployment file must not be written.
    function test_run_writesNoFileOutsideABroadcast() public {
        string memory path = "app/src/config/deployments/rehearsal-only.json";
        vm.setEnv("DEPLOYMENT_FILE", path);
        new DeployTestnet().run();
        assertFalse(vm.exists(path), "no file written");
    }

    /*//////////////////////////////////////////////////////////////
                               APP FLOWS
    //////////////////////////////////////////////////////////////*/

    function test_appFlow_joinWaitForTheLockupThenTransfer() public {
        _join(visitor, SPAIN);
        assertEq(d.token.balanceOf(visitor), NOTES, "ten notes");
        assertEq(d.lockup.unlocksAt(visitor), block.timestamp + 5 minutes, "locked for five minutes");
        assertEq(d.maxHolders.holderCount(), 6, "one more holder");

        // Locked: the lockup module, third in the engine, rejects.
        assertFalse(d.token.canTransfer(visitor, seeds.settled, 1e18), "locked");
        assertFalse(d.lockup.moduleCheck(visitor, seeds.settled, 1e18), "the lockup is the one rejecting");
        vm.prank(visitor);
        vm.expectRevert(
            abi.encodeWithSelector(ISecurityToken.ComplianceCheckFailed.selector, visitor, seeds.settled, 1e18)
        );
        d.token.transfer(seeds.settled, 1e18);

        vm.warp(block.timestamp + 5 minutes);
        _transfer(visitor, seeds.settled, 4e18);
        assertEq(d.maxHolders.holderCount(), 6, "an existing holder received: count unchanged");

        vm.prank(other);
        desk.onboard(SPAIN);
        _transfer(visitor, other, 1e18);
        assertEq(d.maxHolders.holderCount(), 7, "a new holder joined");
        assertEq(d.lockup.unlocksAt(other), block.timestamp + 5 minutes, "the recipient's clock starts");
    }

    function test_appFlow_payACouponThenClaimIt() public {
        _join(visitor, SPAIN);
        vm.warp(desk.nextCouponAt());

        uint256 amount = desk.couponAmount();
        assertEq(amount, 5_050e6, "1,010 notes at 5 EURC");
        vm.prank(visitor);
        desk.payCoupon();

        // 10 of 1,010 notes: 50 EURC, rounded down by at most one unit per holder.
        uint256 owed = distributor.claimable(visitor);
        assertLe(owed, 50e6, "never more than the pro-rata share");
        assertGe(owed, 50e6 - 1, "at most one unit under");

        vm.prank(visitor);
        distributor.claim(visitor);
        assertEq(eurc.balanceOf(visitor), owed, "paid");
        assertEq(distributor.claimable(visitor), 0, "nothing left");
    }

    /// @dev Entitlement does not move with the notes: the seller keeps what accrued while holding.
    function test_appFlow_aTransferLeavesUnclaimedIncomeWithTheSender() public {
        _join(visitor, SPAIN);
        vm.warp(desk.nextCouponAt());
        desk.payCoupon();
        uint256 owed = distributor.claimable(visitor);

        _transfer(visitor, seeds.settled, NOTES);
        assertEq(distributor.claimable(visitor), owed, "still owed after selling out");
        assertEq(d.token.balanceOf(visitor), 0, "sold out");
    }

    function test_appFlow_aRestrictedCountryCannotReceive() public {
        vm.startPrank(visitor);
        desk.onboard(IRAN);
        vm.expectRevert(
            abi.encodeWithSelector(ISecurityToken.ComplianceCheckFailed.selector, address(0), visitor, NOTES)
        );
        desk.claimNotes();
        vm.stopPrank();

        // Declaring another country releases it, which on a real deployment only the agent could do.
        _join(visitor, SPAIN);
        assertEq(d.token.balanceOf(visitor), NOTES, "received after the country change");
    }

    /*//////////////////////////////////////////////////////////////
                         GRIEFING ON A SHARED DEMO
    //////////////////////////////////////////////////////////////*/

    /// @dev Every desk function acts on its caller only: nothing a griefer calls touches a visitor.
    function test_grief_theDeskNeverActsOnAnotherAddress() public {
        _join(visitor, SPAIN);
        bytes32 before = keccak256(abi.encode(d.identityRegistry.identity(visitor)));

        vm.startPrank(griefer);
        desk.onboard(IRAN);
        vm.expectRevert(
            abi.encodeWithSelector(ISecurityToken.ComplianceCheckFailed.selector, address(0), griefer, NOTES)
        );
        desk.claimNotes();
        vm.stopPrank();

        assertEq(keccak256(abi.encode(d.identityRegistry.identity(visitor))), before, "visitor's record untouched");
        assertEq(d.token.balanceOf(visitor), NOTES, "visitor's notes untouched");
        assertEq(desk.nextClaimAt(visitor), block.timestamp + 1 days, "visitor's cooldown untouched");
    }

    /// @dev A dust transfer cannot re-lock a holder: the clock starts on the first acquisition only.
    function test_grief_dustDoesNotRelockAVisitor() public {
        _join(visitor, SPAIN);
        _join(griefer, SPAIN);
        vm.warp(block.timestamp + 5 minutes);
        uint256 unlocksAt = d.lockup.unlocksAt(visitor);

        _transfer(griefer, visitor, 1);
        assertEq(d.lockup.unlocksAt(visitor), unlocksAt, "clock unchanged");
        assertTrue(d.token.canTransfer(visitor, seeds.settled, NOTES), "still free to send");
    }

    /// @dev A full-balance self-transfer leaves the holder count alone, so it cannot fill the cap.
    function test_grief_selfTransfersDoNotInflateTheHolderCount() public {
        _join(griefer, SPAIN);
        vm.warp(block.timestamp + 5 minutes);
        uint256 count = d.maxHolders.holderCount();
        for (uint256 i; i < 5; ++i) {
            _transfer(griefer, griefer, NOTES);
        }
        assertEq(d.maxHolders.holderCount(), count, "count unchanged");
    }

    /// @dev The one thing a stranger can exhaust: with enough addresses the register fills up and a
    ///      newcomer's claim reverts on the cap. Existing holders keep trading, and the agent
    ///      reopens the register with the module's own setter.
    function test_grief_aFullRegisterStopsNewcomersUntilTheAgentRaisesTheCap() public {
        uint256 room = d.maxHolders.maxHolders() - d.maxHolders.holderCount();
        for (uint256 i; i < room; ++i) {
            _join(address(uint160(0x5000 + i)), SPAIN);
        }
        assertEq(d.maxHolders.holderCount(), 499, "register full");

        vm.prank(visitor);
        desk.onboard(SPAIN);
        vm.prank(visitor);
        vm.expectRevert(
            abi.encodeWithSelector(ISecurityToken.ComplianceCheckFailed.selector, address(0), visitor, NOTES)
        );
        desk.claimNotes();

        // An existing holder can still receive and send: the cap only stops new holders.
        vm.warp(block.timestamp + 5 minutes);
        _transfer(address(uint160(0x5000)), seeds.settled, 1e18);

        vm.prank(tx.origin);
        d.maxHolders.setMaxHolders(1_000);
        vm.prank(visitor);
        desk.claimNotes();
        assertEq(d.token.balanceOf(visitor), NOTES, "reopened by the agent");
    }

    function test_grief_couponsCannotBeRushed() public {
        vm.warp(desk.nextCouponAt());
        vm.prank(griefer);
        desk.payCoupon();
        uint256 next = block.timestamp + 10 minutes;
        vm.prank(griefer);
        vm.expectRevert(abi.encodeWithSelector(TestnetDesk.CouponTooSoon.selector, next));
        desk.payCoupon();
    }
}
