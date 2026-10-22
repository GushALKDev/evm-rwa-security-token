// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {Deploy} from "../../Deploy.s.sol";
import {DeployTestnet} from "../DeployTestnet.s.sol";
import {TestnetDesk} from "../TestnetDesk.sol";
import {TestnetEURC} from "../TestnetEURC.sol";
import {DividendDistributor} from "../../../src/compliance/modules/DividendDistributor.sol";
import {IIdentityRegistry} from "../../../src/interfaces/IIdentityRegistry.sol";
import {ISecurityToken} from "../../../src/interfaces/ISecurityToken.sol";

/**
 * @title TestnetDeskTest
 * @notice The desk's three functions and its one-shot wiring, and the testnet EURC it mints, against
 *         a full testnet deployment.
 * @dev Run with FOUNDRY_PROFILE=testnet. Kept out of test/ so the protocol's test figures stay unchanged.
 */
contract TestnetDeskTest is Test {
    uint16 internal constant SPAIN = 724;
    uint16 internal constant IRAN = 364;

    address internal visitor = makeAddr("visitor");
    address internal stranger = makeAddr("stranger");

    Deploy.Deployment internal d;
    TestnetDesk internal desk;
    DividendDistributor internal distributor;
    TestnetEURC internal eurc;
    DeployTestnet.Seeds internal seeds;

    function setUp() public {
        vm.warp(1_800_000_000);
        DeployTestnet script = new DeployTestnet();
        d = script.run();
        (distributor, desk, eurc,) = script.demo();
        seeds = script.seeds();
    }

    /*//////////////////////////////////////////////////////////////
                                ONBOARD
    //////////////////////////////////////////////////////////////*/

    function test_onboard_registersTheCallerForThirtyDays() public {
        vm.prank(visitor);
        desk.onboard(SPAIN);

        IIdentityRegistry.Identity memory id = d.identityRegistry.identity(visitor);
        assertTrue(d.identityRegistry.isVerified(visitor), "verified");
        assertEq(id.country, SPAIN, "country");
        assertFalse(id.accredited, "the desk does not assess accreditation");
        assertEq(id.kycExpiry, block.timestamp + 30 days, "thirty days");
        assertEq(id.investorId, keccak256(abi.encode(visitor)), "default investor id");
    }

    function test_onboard_againChangesTheCountryAndRenewsTheExpiry() public {
        vm.prank(visitor);
        desk.onboard(SPAIN);
        vm.warp(block.timestamp + 10 days);
        vm.prank(visitor);
        desk.onboard(IRAN);

        IIdentityRegistry.Identity memory id = d.identityRegistry.identity(visitor);
        assertEq(id.country, IRAN, "country changed");
        assertEq(id.kycExpiry, block.timestamp + 30 days, "expiry renewed");
    }

    function test_onboard_rejectsACodeOutsideIsoNumeric() public {
        vm.prank(visitor);
        vm.expectRevert(abi.encodeWithSelector(TestnetDesk.InvalidCountry.selector, 0));
        desk.onboard(0);

        vm.prank(visitor);
        vm.expectRevert(abi.encodeWithSelector(TestnetDesk.InvalidCountry.selector, 1000));
        desk.onboard(1000);
    }

    /*//////////////////////////////////////////////////////////////
                              CLAIM NOTES
    //////////////////////////////////////////////////////////////*/

    function test_claimNotes_mintsTenNotesOnceADay() public {
        vm.startPrank(visitor);
        desk.onboard(SPAIN);
        desk.claimNotes();
        vm.stopPrank();

        assertEq(d.token.balanceOf(visitor), 10e18, "ten notes");
        assertEq(desk.nextClaimAt(visitor), block.timestamp + 1 days, "next claim in a day");

        uint256 next = block.timestamp + 1 days;
        vm.warp(next - 1);
        vm.prank(visitor);
        vm.expectRevert(abi.encodeWithSelector(TestnetDesk.ClaimTooSoon.selector, visitor, next));
        desk.claimNotes();

        vm.warp(next);
        vm.prank(visitor);
        desk.claimNotes();
        assertEq(d.token.balanceOf(visitor), 20e18, "second claim");
    }

    /// @dev The mint runs the token's full gate, and a rejected mint reverts the whole call, so the
    ///      day is not used up: the visitor can onboard and claim straight away.
    function test_claimNotes_anUnverifiedCallerIsRejectedByTheGateAndKeepsItsDay() public {
        vm.prank(visitor);
        vm.expectRevert(abi.encodeWithSelector(ISecurityToken.RecipientNotVerified.selector, visitor));
        desk.claimNotes();
        assertEq(desk.nextClaimAt(visitor), 0, "cooldown not consumed");

        vm.startPrank(visitor);
        desk.onboard(SPAIN);
        desk.claimNotes();
        vm.stopPrank();
        assertEq(d.token.balanceOf(visitor), 10e18, "claimed after onboarding");
    }

    function test_claimNotes_aRestrictedCountryIsRejectedByTheCountryRule() public {
        vm.startPrank(visitor);
        desk.onboard(IRAN);
        vm.expectRevert(
            abi.encodeWithSelector(ISecurityToken.ComplianceCheckFailed.selector, address(0), visitor, 10e18)
        );
        desk.claimNotes();
        vm.stopPrank();

        assertFalse(
            d.countryRestriction.moduleCheck(address(0), visitor, 10e18), "the country rule is the one rejecting"
        );
    }

    /*//////////////////////////////////////////////////////////////
                              PAY COUPON
    //////////////////////////////////////////////////////////////*/

    function test_payCoupon_depositsFiveEurcPerNoteOutstanding() public {
        vm.warp(desk.nextCouponAt());
        uint256 dpsBefore = distributor.dividendsPerShare();
        uint256 heldBefore = eurc.balanceOf(address(distributor));

        vm.prank(stranger);
        desk.payCoupon();

        // 1,000 seeded notes at 5 EURC each.
        assertEq(eurc.balanceOf(address(distributor)) - heldBefore, 5_000e6, "coupon deposited");
        assertGt(distributor.dividendsPerShare(), dpsBefore, "accumulator moved");
        assertEq(eurc.balanceOf(address(desk)), 0, "the desk keeps nothing");
        assertEq(eurc.allowance(address(desk), address(distributor)), 0, "no allowance left over");
        assertEq(desk.nextCouponAt(), block.timestamp + 10 minutes, "next coupon in ten minutes");
    }

    function test_payCoupon_revertsBeforeTheInterval() public {
        uint256 next = desk.nextCouponAt();
        vm.warp(next - 1);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(TestnetDesk.CouponTooSoon.selector, next));
        desk.payCoupon();
    }

    /// @dev Rounds down, like every amount the desk derives: the coupon never exceeds 5 EURC per note.
    function test_couponAmount_roundsDown() public {
        // One base unit of note on top of the 1,000 seeded: worth far less than a unit of EURC.
        vm.prank(tx.origin);
        d.token.mint(seeds.settled, 1);
        assertEq(desk.couponAmount(), 5_000e6, "rounded down to whole units");
    }

    /*//////////////////////////////////////////////////////////////
                                 WIRING
    //////////////////////////////////////////////////////////////*/

    function test_setDistributor_onceAndOwnerOnly() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        desk.setDistributor(address(distributor));

        vm.prank(desk.owner());
        vm.expectRevert(abi.encodeWithSelector(TestnetDesk.DistributorAlreadySet.selector, address(distributor)));
        desk.setDistributor(address(distributor));
    }

    /// @dev A second desk mints its own currency, so the live distributor does not match it.
    function test_setDistributor_rejectsADistributorOfAnotherCurrency() public {
        TestnetDesk fresh = new TestnetDesk(address(this), address(d.identityRegistry), address(d.token));
        vm.expectRevert(abi.encodeWithSelector(TestnetDesk.DistributorMismatch.selector, address(distributor)));
        fresh.setDistributor(address(distributor));
    }

    function test_payCoupon_revertsUntilWired() public {
        TestnetDesk fresh = new TestnetDesk(address(this), address(d.identityRegistry), address(d.token));
        vm.expectRevert(TestnetDesk.DistributorNotSet.selector);
        fresh.payCoupon();
    }

    function test_constructor_rejectsZeroAddresses() public {
        vm.expectRevert(TestnetDesk.ZeroAddress.selector);
        new TestnetDesk(address(this), address(0), address(d.token));
        vm.expectRevert(TestnetDesk.ZeroAddress.selector);
        new TestnetDesk(address(this), address(d.identityRegistry), address(0));
    }

    /*//////////////////////////////////////////////////////////////
                              TESTNET EURC
    //////////////////////////////////////////////////////////////*/

    function test_eurc_hasSixDecimalsAndOnlyTheDeskMints() public {
        assertEq(eurc.decimals(), 6, "decimals");
        assertEq(eurc.minter(), address(desk), "the desk is the minter");

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(TestnetEURC.OnlyMinter.selector, stranger));
        eurc.mint(stranger, 1);
    }
}
