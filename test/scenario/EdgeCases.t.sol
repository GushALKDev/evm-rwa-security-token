// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {Deploy} from "../../script/Deploy.s.sol";
import {ISecurityToken} from "../../src/interfaces/ISecurityToken.sol";
import {IDividendDistributor} from "../../src/interfaces/IDividendDistributor.sol";
import {IModularCompliance} from "../../src/interfaces/IModularCompliance.sol";
import {MaxHoldersModule} from "../../src/compliance/modules/MaxHoldersModule.sol";
import {DividendDistributor} from "../../src/compliance/modules/DividendDistributor.sol";
import {MockCurrency} from "../helpers/MockCurrency.sol";

/**
 * @title EdgeCasesTest
 * @notice Edge cases and griefing vectors the unit suites do not reach, run against the system
 *         `Deploy` produces. The edge case table in docs/04-tradeoffs.md points at each test by name.
 */
contract EdgeCasesTest is Test, Deploy {
    Deployment internal d;

    address internal issuer = address(this);
    address internal agent = makeAddr("agent");
    address internal custodian = makeAddr("custodian");
    address internal alice = makeAddr("alice");
    address internal aliceNew = makeAddr("aliceNew");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    uint16 internal constant ES = 724;
    uint16 internal constant FR = 250;
    uint64 internal constant KYC_WINDOW = 10 * 365 days;
    uint256 internal constant AMOUNT = 1_000e18;

    function setUp() public {
        d = _deploy(issuer, agent, custodian);
    }

    function _onboard(address who) internal {
        vm.prank(agent);
        d.identityRegistry.registerIdentity(who, ES, true, uint64(block.timestamp + KYC_WINDOW));
    }

    function _onboardAs(address who, uint16 country, bytes32 id) internal {
        vm.prank(agent);
        d.identityRegistry.registerIdentity(who, country, true, uint64(block.timestamp + KYC_WINDOW), id);
    }

    function _attachDistributor(ERC20 currency) internal returns (DividendDistributor dist) {
        dist = new DividendDistributor(address(d.compliance), address(d.token), address(currency), issuer);
        d.compliance.addModule(address(dist));
    }

    function _fundedDistributor() internal returns (DividendDistributor dist, MockCurrency currency) {
        currency = new MockCurrency();
        dist = _attachDistributor(currency);
        currency.mint(issuer, 1_000_000e6);
        currency.approve(address(dist), type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                              HOLDER CAP
    //////////////////////////////////////////////////////////////*/

    /// @dev The cap cannot go below the live count. Set to exactly the count, it refuses a new
    ///      holder, admits a swap, and admits a new holder again once an exit frees a place.
    function test_holderCap_loweredToCount_thenExitsAndEntries() public {
        _onboard(alice);
        _onboard(bob);
        _onboard(carol);
        d.token.mint(alice, AMOUNT);
        d.token.mint(bob, AMOUNT);

        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(MaxHoldersModule.MaxHoldersBelowCurrentCount.selector, 1, 2));
        d.maxHolders.setMaxHolders(1);
        vm.prank(agent);
        d.maxHolders.setMaxHolders(2);

        vm.expectRevert(abi.encodeWithSelector(ISecurityToken.ComplianceCheckFailed.selector, address(0), carol, 1));
        d.token.mint(carol, 1);

        vm.warp(block.timestamp + LOCKUP_PERIOD + 1);
        vm.prank(alice);
        d.token.transfer(carol, AMOUNT); // swap at the cap: alice leaves, carol joins
        assertEq(d.maxHolders.holderCount(), 2);

        d.token.burn(bob, AMOUNT); // an exit frees a place
        d.token.mint(alice, 1);
        assertEq(d.maxHolders.holderCount(), 2);
    }

    /*//////////////////////////////////////////////////////////////
                                LOCKUP
    //////////////////////////////////////////////////////////////*/

    /// @dev setLockupPeriod applies to clocks already running: lengthening it re-locks a holder
    ///      whose original period had expired, shortening it releases one early. Documented.
    function test_setLockupPeriod_appliesRetroactively() public {
        _onboard(alice);
        _onboard(bob);
        d.token.mint(alice, AMOUNT);
        vm.warp(block.timestamp + LOCKUP_PERIOD + 1);
        assertTrue(d.token.canTransfer(alice, bob, 1));

        vm.prank(agent);
        d.lockup.setLockupPeriod(LOCKUP_PERIOD * 2);
        assertFalse(d.token.canTransfer(alice, bob, 1), "lengthening re-locked the holder");

        vm.prank(agent);
        d.lockup.setLockupPeriod(1 days);
        assertTrue(d.token.canTransfer(alice, bob, 1), "shortening released the holder");
    }

    /// @dev A KYC that expires during the lockup suspends the position; renewing it restores the
    ///      same lockup schedule, and income accrued meanwhile is released too.
    function test_kycExpiryDuringLockupAndWithUnclaimedIncome() public {
        (DividendDistributor dist, MockCurrency currency) = _fundedDistributor();
        vm.prank(agent);
        d.identityRegistry.registerIdentity(alice, ES, true, uint64(block.timestamp + 30 days));
        _onboard(bob);
        d.token.mint(alice, AMOUNT);
        uint64 unlocksAt = d.lockup.unlocksAt(alice);
        dist.deposit(900e6);

        vm.warp(block.timestamp + 30 days);
        assertFalse(d.identityRegistry.isVerified(alice));
        vm.expectRevert(abi.encodeWithSelector(ISecurityToken.SenderNotVerified.selector, alice));
        vm.prank(alice);
        d.token.transfer(bob, 1);
        vm.expectRevert(abi.encodeWithSelector(IDividendDistributor.ClaimantNotVerified.selector, alice));
        vm.prank(alice);
        dist.claim(alice);

        _onboard(alice);
        assertEq(d.lockup.unlocksAt(alice), unlocksAt, "renewal moved the lockup");
        vm.prank(alice);
        dist.claim(alice);
        assertEq(currency.balanceOf(alice), 900e6 - 1);
    }

    /// @dev Removing the lockup releases every locked holder at once, and it cannot be put back:
    ///      the token has supply and the module was attached before.
    function test_removingLockup_releasesLockedHolders_andCannotReturn() public {
        _onboard(alice);
        _onboard(bob);
        d.token.mint(alice, AMOUNT);
        assertFalse(d.token.canTransfer(alice, bob, 1));

        d.compliance.removeModule(address(d.lockup));
        vm.prank(alice);
        d.token.transfer(bob, 1);

        vm.expectRevert(abi.encodeWithSelector(IModularCompliance.ModuleCannotBind.selector, address(d.lockup)));
        d.compliance.addModule(address(d.lockup));
    }

    /*//////////////////////////////////////////////////////////////
                               RECOVERY
    //////////////////////////////////////////////////////////////*/

    /// @dev Recovery into a wallet of the same investor registered in a blocked jurisdiction
    ///      succeeds: recovery skips the modular rules by design. The position then cannot be
    ///      transferred onward to anyone in that jurisdiction, like any other holding there.
    function test_recovery_intoBlockedJurisdictionWalletOfSameInvestor() public {
        bytes32 id = keccak256("investor-alice");
        _onboardAs(alice, ES, id);
        _onboardAs(aliceNew, FR, id);
        d.token.mint(alice, AMOUNT);
        vm.prank(agent);
        d.countryRestriction.setCountryRestricted(FR, true);

        vm.prank(custodian);
        d.token.forcedRecovery(alice, aliceNew);
        assertEq(d.token.balanceOf(aliceNew), AMOUNT);
    }

    /// @dev A recovered lost wallet cannot claim: it is unverified, and once registered again it
    ///      has nothing left, because recovery moved its entitlement.
    function test_recoveredLostWallet_cannotClaim() public {
        (DividendDistributor dist,) = _fundedDistributor();
        bytes32 id = keccak256("investor-alice");
        _onboardAs(alice, ES, id);
        _onboardAs(aliceNew, ES, id);
        d.token.mint(alice, AMOUNT);
        dist.deposit(900e6);

        vm.prank(custodian);
        d.token.forcedRecovery(alice, aliceNew);

        vm.expectRevert(abi.encodeWithSelector(IDividendDistributor.ClaimantNotVerified.selector, alice));
        vm.prank(alice);
        dist.claim(alice);

        _onboard(alice);
        vm.expectRevert(abi.encodeWithSelector(IDividendDistributor.NothingToClaim.selector, alice));
        vm.prank(alice);
        dist.claim(alice);

        assertGe(dist.claimable(aliceNew) + 1, 900e6);
    }

    /*//////////////////////////////////////////////////////////////
                               DIVIDENDS
    //////////////////////////////////////////////////////////////*/

    /// @dev The smallest supply: one base unit, and deposits of one currency unit, pay out exactly.
    function test_dividends_smallestSupplyAndDeposit() public {
        (DividendDistributor dist, MockCurrency currency) = _fundedDistributor();
        _onboard(alice);
        d.token.mint(alice, 1);

        dist.deposit(1);
        assertEq(dist.claimable(alice), 1);
        dist.deposit(1);
        vm.prank(alice);
        dist.claim(alice);
        assertEq(currency.balanceOf(alice), 2);
    }

    /// @dev Currency sent straight to the distributor, outside `deposit`, is not credited to anyone
    ///      and does not disturb what holders are owed.
    function test_dividends_directDonationIsNotCredited() public {
        (DividendDistributor dist, MockCurrency currency) = _fundedDistributor();
        _onboard(alice);
        d.token.mint(alice, AMOUNT);
        dist.deposit(900e6);
        uint256 owed = dist.claimable(alice);

        currency.transfer(address(dist), 5_000e6);
        assertEq(dist.claimable(alice), owed);
    }

    /// @dev A currency whose `transfer` returns false fails the claim through SafeERC20, and the
    ///      claim leaves no record, so it can be retried once the currency pays.
    function test_dividends_currencyReturningFalse_failsTheClaimCleanly() public {
        FlakyCurrency currency = new FlakyCurrency();
        DividendDistributor dist = _attachDistributor(currency);
        currency.mint(issuer, 1_000e6);
        currency.approve(address(dist), type(uint256).max);
        _onboard(alice);
        d.token.mint(alice, AMOUNT);
        dist.deposit(900e6);

        currency.setMode(FlakyCurrency.Mode.ReturnFalse);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(currency)));
        vm.prank(alice);
        dist.claim(alice);
        assertEq(dist.withdrawn(alice), 0);

        currency.setMode(FlakyCurrency.Mode.Revert);
        vm.expectRevert(FlakyCurrency.Refused.selector);
        vm.prank(alice);
        dist.claim(alice);

        currency.setMode(FlakyCurrency.Mode.Normal);
        vm.prank(alice);
        dist.claim(alice);
        assertEq(currency.balanceOf(alice), 900e6 - 1);
    }

    /// @dev A currency whose `transferFrom` returns false fails the deposit, and the accumulator
    ///      does not move.
    function test_dividends_currencyReturningFalse_failsTheDepositCleanly() public {
        FlakyCurrency currency = new FlakyCurrency();
        DividendDistributor dist = _attachDistributor(currency);
        currency.mint(issuer, 1_000e6);
        currency.approve(address(dist), type(uint256).max);
        _onboard(alice);
        d.token.mint(alice, AMOUNT);

        currency.setMode(FlakyCurrency.Mode.ReturnFalse);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(currency)));
        dist.deposit(900e6);
        assertEq(dist.dividendsPerShare(), 0);
    }

    /*//////////////////////////////////////////////////////////////
                           PAUSE AND ROLES
    //////////////////////////////////////////////////////////////*/

    /// @dev What a pause stops and what it does not. It stops every token movement except forced
    ///      recovery: mint, burn, transfer and transferFrom. It does not stop administration
    ///      (freezes, identity changes, rule parameters, module changes) or the distributor, whose
    ///      deposit and claim move the settlement currency, not the token. Documented.
    function test_pause_againstEachRoleAction() public {
        (DividendDistributor dist,) = _fundedDistributor();
        bytes32 id = keccak256("investor-alice");
        _onboardAs(alice, ES, id);
        _onboardAs(aliceNew, ES, id);
        _onboard(bob);
        d.token.mint(alice, AMOUNT);
        d.token.mint(bob, AMOUNT);
        dist.deposit(900e6);
        vm.warp(block.timestamp + LOCKUP_PERIOD + 1);
        vm.prank(bob);
        d.token.approve(carol, AMOUNT);

        vm.prank(agent);
        d.token.pause();

        // Stopped.
        vm.expectRevert(Pausable.EnforcedPause.selector);
        d.token.mint(bob, 1);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        d.token.burn(bob, 1);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(bob);
        d.token.transfer(alice, 1);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(carol);
        d.token.transferFrom(bob, alice, 1);

        // Not stopped: agent administration.
        vm.startPrank(agent);
        d.token.freezePartialTokens(bob, 1);
        d.token.unfreezePartialTokens(bob, 1);
        d.token.setAddressFrozen(bob, true);
        d.token.setAddressFrozen(bob, false);
        d.identityRegistry.registerIdentity(carol, ES, true, uint64(block.timestamp + KYC_WINDOW));
        d.identityRegistry.removeIdentity(carol);
        d.maxHolders.setMaxHolders(100);
        d.lockup.setLockupPeriod(LOCKUP_PERIOD);
        d.countryRestriction.setCountryRestricted(FR, true);
        vm.stopPrank();

        // Not stopped: issuer administration and the distributor.
        d.compliance.removeModule(address(d.countryRestriction));
        dist.deposit(900e6);
        vm.prank(bob);
        dist.claim(bob);

        // Not stopped by design: custodian recovery.
        vm.prank(custodian);
        d.token.forcedRecovery(alice, aliceNew);
        assertEq(d.token.balanceOf(aliceNew), AMOUNT);
    }

    /*//////////////////////////////////////////////////////////////
                           DOCUMENT REGISTRY
    //////////////////////////////////////////////////////////////*/

    /// @dev Names are fixed 32-byte labels, so the longest name is 32 bytes; URIs have no length
    ///      limit beyond gas. A 4 KiB URI is stored and read back intact.
    function test_documents_longestNameAndLongUri() public {
        bytes32 longest = bytes32(type(uint256).max);
        bytes memory uri = new bytes(4096);
        for (uint256 i; i < uri.length; ++i) {
            uri[i] = "a";
        }
        d.documentRegistry.setDocument(longest, string(uri), keccak256("x"));
        (string memory read,,) = d.documentRegistry.getDocument(longest);
        assertEq(bytes(read).length, 4096);
    }
}

/// @notice A settlement currency that can be switched to return false or revert on transfers.
contract FlakyCurrency is ERC20 {
    enum Mode {
        Normal,
        ReturnFalse,
        Revert
    }

    error Refused();

    Mode public mode;

    constructor() ERC20("Flaky USD", "fUSD") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setMode(Mode mode_) external {
        mode = mode_;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (mode == Mode.ReturnFalse) return false;
        if (mode == Mode.Revert) revert Refused();
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (mode == Mode.ReturnFalse) return false;
        if (mode == Mode.Revert) revert Refused();
        return super.transferFrom(from, to, amount);
    }
}
