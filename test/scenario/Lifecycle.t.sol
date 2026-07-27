// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {Deploy} from "../../script/Deploy.s.sol";
import {ISecurityToken} from "../../src/interfaces/ISecurityToken.sol";
import {Roles} from "../../src/Roles.sol";

/**
 * @title LifecycleTest
 * @notice End-to-end scenarios over the fully wired system.
 * @dev These differ from the unit suites in two ways that are the point of having them.
 *
 *      First, nothing is mocked: the system is the one `Deploy` produces, with the real engine,
 *      the real registry and all three rule modules registered, at the real 365-day lockup. A unit
 *      test proves a contract honours its own contract; these prove the composition behaves like
 *      the instrument it is meant to model.
 *
 *      Second, each test is a sequence rather than a single call, because the interesting failures
 *      live in the ordering. A freeze that survives a recovery, a lockup clock that a partial exit
 *      must not reset, a holder slot that only frees when a wallet empties: none of these are
 *      observable from one transaction.
 */
contract LifecycleTest is Test, Deploy {
    Deployment internal d;

    address internal issuer = address(this);
    address internal agent = makeAddr("agent");
    address internal custodian = makeAddr("custodian");

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    uint16 internal constant ES = 724;
    uint16 internal constant FR = 250;

    /// @dev Comfortably longer than LOCKUP_PERIOD, so a warp past the lockup never trips an
    ///      expired attestation and make a test assert the wrong rejection.
    uint64 internal constant KYC_WINDOW = 10 * 365 days;

    uint256 internal constant AMOUNT = 1_000e18;

    function setUp() public {
        d = _deploy(issuer, agent, custodian);
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _onboard(address who, uint16 country) internal {
        vm.prank(agent);
        d.identityRegistry.registerIdentity(who, country, true, uint64(block.timestamp + KYC_WINDOW));
    }

    function _onboardAs(address who, uint16 country, bytes32 id) internal {
        vm.prank(agent);
        d.identityRegistry.registerIdentity(who, country, true, uint64(block.timestamp + KYC_WINDOW), id);
    }

    function _passLockup() internal {
        vm.warp(block.timestamp + LOCKUP_PERIOD + 1);
    }

    /*//////////////////////////////////////////////////////////////
                       1. THE ORDINARY LIFE OF A NOTE
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Onboard, subscribe, be held to the lockup, trade once free, then be partially redeemed.
     *      This is the path every holder is expected to walk, and it is the one that must not
     *      require any privileged intervention beyond issuance itself.
     */
    function test_scenario_subscribeHoldTradeRedeem() public {
        _onboard(alice, ES);
        _onboard(bob, ES);

        // Primary issuance. The subscriber becomes a holder and their lockup clock starts.
        d.token.mint(alice, AMOUNT);
        assertEq(d.token.balanceOf(alice), AMOUNT);
        assertEq(d.maxHolders.holderCount(), 1);

        // Inside the holding period the position cannot be sold on.
        vm.expectPartialRevert(ISecurityToken.ComplianceCheckFailed.selector);
        vm.prank(alice);
        d.token.transfer(bob, AMOUNT / 2);

        _passLockup();

        // Once the period has run, the same transfer settles.
        vm.prank(alice);
        d.token.transfer(bob, AMOUNT / 2);
        assertEq(d.token.balanceOf(bob), AMOUNT / 2);
        assertEq(d.maxHolders.holderCount(), 2);

        // The issuer retires part of the position, as a redemption would.
        d.token.burn(alice, AMOUNT / 4);
        assertEq(d.token.totalSupply(), AMOUNT - AMOUNT / 4);
        // Alice still holds a balance, so she is still a holder.
        assertEq(d.maxHolders.holderCount(), 2);
    }

    /**
     * @dev A buyer inherits the lockup on what they receive: the clock is a property of the
     *      acquisition, not of the wallet, so a position cannot be freed by passing it along.
     */
    function test_scenario_lockupFollowsTheAcquisition() public {
        _onboard(alice, ES);
        _onboard(bob, ES);
        _onboard(carol, ES);

        d.token.mint(alice, AMOUNT);
        _passLockup();

        vm.prank(alice);
        d.token.transfer(bob, AMOUNT / 2);

        // Bob acquired just now, so his own clock is running even though Alice's had expired.
        vm.expectPartialRevert(ISecurityToken.ComplianceCheckFailed.selector);
        vm.prank(bob);
        d.token.transfer(carol, 1e18);
    }

    /*//////////////////////////////////////////////////////////////
                        2. INCIDENT AND RECOVERY
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev The incident this instrument is built to survive: an investor's key is compromised, the
     *      desk halts trading, and the custodian relocates the position to the investor's other
     *      wallet. Recovery must work while paused and while the lockup is still running, or the
     *      halt meant to contain the incident would strand the position instead.
     */
    function test_scenario_compromisedKeyRecoveredUnderPause() public {
        bytes32 aliceId = keccak256("investor-alice");
        _onboardAs(alice, ES, aliceId);
        address aliceBackup = makeAddr("aliceBackup");
        _onboardAs(aliceBackup, ES, aliceId);

        d.token.mint(alice, AMOUNT);

        // Part of the position is under an operational hold when the incident happens.
        vm.prank(agent);
        d.token.freezePartialTokens(alice, AMOUNT / 4);

        // The desk halts the market on discovering the compromise.
        vm.prank(agent);
        d.token.pause();

        // Ordinary trading is stopped.
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(alice);
        d.token.transfer(bob, 1e18);

        // Recovery still runs: paused, still inside the lockup, and with a hold in place.
        vm.prank(custodian);
        d.token.forcedRecovery(alice, aliceBackup);

        assertEq(d.token.balanceOf(aliceBackup), AMOUNT);
        assertEq(d.token.balanceOf(alice), 0);
        assertEq(d.token.totalSupply(), AMOUNT, "recovery must not change supply");

        // The hold travelled with the position rather than being dropped.
        assertEq(d.token.frozenTokens(aliceBackup), AMOUNT / 4);

        // The compromised wallet is retired for good.
        assertFalse(d.identityRegistry.isVerified(alice));

        vm.prank(agent);
        d.token.unpause();

        // The recovered position is still subject to the hold: only the unfrozen part can move.
        _passLockup();
        _onboard(bob, ES);
        vm.prank(aliceBackup);
        d.token.transfer(bob, AMOUNT - AMOUNT / 4);
        assertEq(d.token.balanceOf(aliceBackup), AMOUNT / 4);

        vm.expectPartialRevert(ISecurityToken.InsufficientUnfrozenBalance.selector);
        vm.prank(aliceBackup);
        d.token.transfer(bob, 1);
    }

    /// @dev A retired wallet is not merely emptied, it is barred: it can never receive again
    ///      unless compliance deliberately re-onboards it.
    function test_scenario_retiredWalletCannotBeUsedAgain() public {
        bytes32 aliceId = keccak256("investor-alice");
        _onboardAs(alice, ES, aliceId);
        address aliceBackup = makeAddr("aliceBackup");
        _onboardAs(aliceBackup, ES, aliceId);
        _onboard(bob, ES);

        d.token.mint(alice, AMOUNT);
        vm.prank(custodian);
        d.token.forcedRecovery(alice, aliceBackup);

        d.token.mint(bob, AMOUNT);
        _passLockup();

        vm.expectRevert(abi.encodeWithSelector(ISecurityToken.RecipientNotVerified.selector, alice));
        vm.prank(bob);
        d.token.transfer(alice, 1e18);
    }

    /*//////////////////////////////////////////////////////////////
                             3. SANCTION
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Compliance withdraws an investor's identity, which is what happens when they may no
     *      longer hold the instrument at all. The position must be immobilised in both directions:
     *      a rule that only blocked incoming transfers would leave the sanctioned party free to
     *      sell out. The tokens survive, because losing an attestation does not extinguish title.
     */
    function test_scenario_withdrawnIdentitySuspendsPosition() public {
        _onboard(alice, ES);
        _onboard(bob, ES);

        d.token.mint(alice, AMOUNT);
        _passLockup();

        vm.prank(agent);
        d.identityRegistry.removeIdentity(alice);

        // Cannot sell out.
        vm.expectRevert(abi.encodeWithSelector(ISecurityToken.SenderNotVerified.selector, alice));
        vm.prank(alice);
        d.token.transfer(bob, 1e18);

        // Cannot be topped up either.
        d.token.mint(bob, AMOUNT);
        _passLockup();
        vm.expectRevert(abi.encodeWithSelector(ISecurityToken.RecipientNotVerified.selector, alice));
        vm.prank(bob);
        d.token.transfer(alice, 1e18);

        // The balance is untouched throughout: suspended, not confiscated.
        assertEq(d.token.balanceOf(alice), AMOUNT);

        // The issuer can still retire it, which is the lawful way out.
        d.token.burn(alice, AMOUNT);
        assertEq(d.token.balanceOf(alice), 0);
    }

    /// @dev The suspension lifts when compliance re-verifies, so it is a reversible measure
    ///      rather than a permanent seizure.
    function test_scenario_reverificationReleasesPosition() public {
        _onboard(alice, ES);
        _onboard(bob, ES);

        d.token.mint(alice, AMOUNT);
        _passLockup();

        vm.prank(agent);
        d.identityRegistry.removeIdentity(alice);
        _onboard(alice, ES);

        vm.prank(alice);
        d.token.transfer(bob, AMOUNT);
        assertEq(d.token.balanceOf(bob), AMOUNT);
    }

    /*//////////////////////////////////////////////////////////////
                          4. THE HOLDER CAP
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev A private placement is capped. Once full, a new subscriber is refused, but a seat that
     *      frees up can be taken: the cap limits concurrent holders, not participation over time.
     *      Run against a cap lowered to the current count, since the deployed cap is 499.
     */
    function test_scenario_capRefusesNewHolderThenAdmitsReplacement() public {
        _onboard(alice, ES);
        _onboard(bob, ES);
        _onboard(carol, ES);

        d.token.mint(alice, AMOUNT);
        d.token.mint(bob, AMOUNT);
        assertEq(d.maxHolders.holderCount(), 2);

        // The placement is now full.
        vm.prank(agent);
        d.maxHolders.setMaxHolders(2);

        // A third subscriber cannot be admitted.
        vm.expectPartialRevert(ISecurityToken.ComplianceCheckFailed.selector);
        d.token.mint(carol, AMOUNT);

        // Bob exits completely, freeing his seat.
        _passLockup();
        vm.prank(bob);
        d.token.transfer(alice, AMOUNT);
        assertEq(d.maxHolders.holderCount(), 1);

        // Carol can now subscribe.
        d.token.mint(carol, AMOUNT);
        assertEq(d.maxHolders.holderCount(), 2);
    }

    /// @dev A transfer that empties the sender while filling a new holder keeps the count flat, so
    ///      it is allowed even with the placement full: one holder replaces another atomically.
    function test_scenario_replacementAtCapIsAllowed() public {
        _onboard(alice, ES);
        _onboard(bob, ES);

        d.token.mint(alice, AMOUNT);
        vm.prank(agent);
        d.maxHolders.setMaxHolders(1);

        _passLockup();

        // Alice sends her entire balance to a wallet that holds nothing.
        vm.prank(alice);
        d.token.transfer(bob, AMOUNT);

        assertEq(d.maxHolders.holderCount(), 1);
        assertEq(d.token.balanceOf(alice), 0);
        assertEq(d.token.balanceOf(bob), AMOUNT);
    }

    /*//////////////////////////////////////////////////////////////
                           5. JURISDICTION
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev A jurisdiction is closed after the fact. The rule is recipient-side, so an existing
     *      holder in that country keeps their position and can still sell out; what they cannot do
     *      is receive more. Blocking their exit too would trap them, which is not what a
     *      distribution restriction means.
     */
    function test_scenario_closingAJurisdictionBlocksInboundOnly() public {
        _onboard(alice, ES);
        _onboard(bob, FR);

        d.token.mint(alice, AMOUNT);
        d.token.mint(bob, AMOUNT);
        _passLockup();

        // Trading into France is fine to begin with.
        vm.prank(alice);
        d.token.transfer(bob, 1e18);

        // The desk closes the jurisdiction.
        vm.prank(agent);
        d.countryRestriction.setCountryRestricted(FR, true);

        // No more can be distributed into it.
        vm.expectPartialRevert(ISecurityToken.ComplianceCheckFailed.selector);
        vm.prank(alice);
        d.token.transfer(bob, 1e18);

        // But the existing holder there is not trapped: the restriction is recipient-side, so bob
        // can still sell out. He returns the 1e18 he received, leaving both back where they began.
        vm.prank(bob);
        d.token.transfer(alice, 1e18);
        assertEq(d.token.balanceOf(alice), AMOUNT);
        assertEq(d.token.balanceOf(bob), AMOUNT);
    }

    /*//////////////////////////////////////////////////////////////
                      6. RULES COMPOSE, NOT OVERRIDE
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Every rule must pass, so clearing one is not enough. Walk a transfer past each blocker
     *      in turn and confirm it only settles once the last one is cleared.
     */
    function test_scenario_everyRuleMustPassIndependently() public {
        _onboard(alice, ES);
        _onboard(bob, FR);

        d.token.mint(alice, AMOUNT);

        vm.startPrank(agent);
        d.countryRestriction.setCountryRestricted(FR, true);
        d.token.freezePartialTokens(alice, AMOUNT);
        vm.stopPrank();

        // Blocked by the lockup, the country rule and the partial freeze at once.
        vm.expectPartialRevert(ISecurityToken.InsufficientUnfrozenBalance.selector);
        vm.prank(alice);
        d.token.transfer(bob, 1e18);

        // Release the freeze: still blocked, now by the lockup.
        vm.prank(agent);
        d.token.unfreezePartialTokens(alice, AMOUNT);
        vm.expectPartialRevert(ISecurityToken.ComplianceCheckFailed.selector);
        vm.prank(alice);
        d.token.transfer(bob, 1e18);

        // Clear the lockup: still blocked, now only by the country rule.
        _passLockup();
        vm.expectPartialRevert(ISecurityToken.ComplianceCheckFailed.selector);
        vm.prank(alice);
        d.token.transfer(bob, 1e18);

        // Reopen the jurisdiction: nothing is left to reject it.
        vm.prank(agent);
        d.countryRestriction.setCountryRestricted(FR, false);
        vm.prank(alice);
        d.token.transfer(bob, 1e18);

        assertEq(d.token.balanceOf(bob), 1e18);
    }
}
