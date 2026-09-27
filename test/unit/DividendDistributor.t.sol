// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {DividendDistributor} from "../../src/compliance/modules/DividendDistributor.sol";
import {IComplianceModule} from "../../src/interfaces/IComplianceModule.sol";
import {IDividendDistributor} from "../../src/interfaces/IDividendDistributor.sol";
import {Roles} from "../../src/Roles.sol";
import {MockCurrency} from "../helpers/MockCurrency.sol";
import {MockToken} from "../helpers/MockToken.sol";

contract DividendDistributorTest is Test {
    DividendDistributor internal dist;
    MockToken internal token;
    MockCurrency internal currency;

    address internal engine = makeAddr("compliance");
    address internal issuer = makeAddr("issuer");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    uint256 internal constant SHARES = 1_000e18;
    uint256 internal constant INCOME = 900e6;

    /// @dev Per-holder descaling truncates down by at most one wei, which is what keeps the
    ///      contract solvent. Exact-equality assertions on a payout would be asserting a rounding
    ///      direction the design deliberately does not promise.
    uint256 internal constant DUST = 1;

    function setUp() public {
        token = new MockToken();
        currency = new MockCurrency();
        dist = new DividendDistributor(engine, address(token), address(currency), issuer);
        // The engine attaches a module when it registers it; deposits require that attachment.
        vm.prank(engine);
        dist.bindCompliance(engine);

        currency.mint(issuer, 1_000_000e6);
        vm.prank(issuer);
        currency.approve(address(dist), type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Mirrors the engine: balances move first, then the hook fires.
    function _mint(address to, uint256 amount) internal {
        token.mint(to, amount);
        vm.prank(engine);
        dist.moduleCreated(to, amount);
    }

    function _transfer(address from, address to, uint256 amount) internal {
        vm.prank(from);
        token.transfer(to, amount);
        vm.prank(engine);
        dist.moduleTransferred(from, to, amount);
    }

    function _burn(address from, uint256 amount) internal {
        token.burn(from, amount);
        vm.prank(engine);
        dist.moduleDestroyed(from, amount);
    }

    function _deposit(uint256 amount) internal {
        vm.prank(issuer);
        dist.deposit(amount);
    }

    /// @dev Asserts an entitlement equals `expected` up to the one-wei descaling truncation, and
    ///      never exceeds it. Overpaying by even one wei is a solvency bug, so the bound is
    ///      deliberately one-sided.
    function _assertOwed(uint256 actual, uint256 expected, string memory reason) internal pure {
        assertLe(actual, expected, reason);
        assertGe(actual + DUST, expected, reason);
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @dev Stateful but supply-agnostic: it may join a live token, once. setUp already attached it.
    function test_attachment_lateOnceOnly() public {
        assertFalse(dist.isPlugAndPlay());
        _mint(alice, SHARES);
        assertTrue(dist.isComplianceBound(engine));
        assertFalse(dist.canComplianceBind(engine), "an attached distributor must not bind again");
    }

    function test_constructor_setsState() public view {
        assertEq(dist.compliance(), engine);
        assertEq(dist.token(), address(token));
        assertEq(dist.currency(), address(currency));
        assertEq(dist.dividendsPerShare(), 0);
        assertEq(dist.name(), "DividendDistributor");
        assertTrue(dist.hasRole(dist.DEFAULT_ADMIN_ROLE(), issuer));
        assertTrue(dist.hasRole(Roles.AGENT_ROLE, issuer));
    }

    function test_constructor_revertsOnZeroToken() public {
        vm.expectRevert(IDividendDistributor.ZeroAddress.selector);
        new DividendDistributor(engine, address(0), address(currency), issuer);
    }

    function test_constructor_revertsOnZeroCurrency() public {
        vm.expectRevert(IDividendDistributor.ZeroAddress.selector);
        new DividendDistributor(engine, address(token), address(0), issuer);
    }

    function test_constructor_revertsOnZeroIssuer() public {
        vm.expectRevert(IDividendDistributor.ZeroAddress.selector);
        new DividendDistributor(engine, address(token), address(currency), address(0));
    }

    function test_constructor_revertsOnZeroCompliance() public {
        vm.expectRevert(abi.encodeWithSelector(IComplianceModule.OnlyCompliance.selector, address(0), address(0)));
        new DividendDistributor(address(0), address(token), address(currency), issuer);
    }

    /*//////////////////////////////////////////////////////////////
                                DEPOSIT
    //////////////////////////////////////////////////////////////*/

    function test_deposit_pullsFundsAndRaisesAccumulator() public {
        _mint(alice, SHARES);

        vm.expectEmit(true, false, false, false, address(dist));
        emit IDividendDistributor.DividendsDeposited(issuer, INCOME, 0);
        _deposit(INCOME);

        assertEq(currency.balanceOf(address(dist)), INCOME);
        assertGt(dist.dividendsPerShare(), 0);
    }

    function test_deposit_revertsOnZeroAmount() public {
        _mint(alice, SHARES);

        vm.prank(issuer);
        vm.expectRevert(IDividendDistributor.ZeroDeposit.selector);
        dist.deposit(0);
    }

    /// @dev Depositing with no supply would credit no one and strand the funds forever.
    function test_deposit_revertsOnZeroSupply() public {
        vm.prank(issuer);
        vm.expectRevert(IDividendDistributor.NoSupply.selector);
        dist.deposit(INCOME);
    }

    function test_deposit_revertsForNonAgent() public {
        _mint(alice, SHARES);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, Roles.AGENT_ROLE)
        );
        dist.deposit(INCOME);
    }

    /*//////////////////////////////////////////////////////////////
                                 CLAIM
    //////////////////////////////////////////////////////////////*/

    function test_claim_paysSoleHolderTheWholeDeposit() public {
        _mint(alice, SHARES);
        _deposit(INCOME);

        uint256 owed = dist.claimable(alice);
        _assertOwed(owed, INCOME, "sole holder takes the deposit less dust");

        vm.expectEmit(true, true, false, true, address(dist));
        emit IDividendDistributor.DividendsClaimed(alice, alice, owed);
        vm.prank(alice);
        dist.claim(alice);

        assertEq(currency.balanceOf(alice), owed);
        assertEq(dist.claimable(alice), 0);
        assertEq(dist.withdrawn(alice), owed);
    }

    function test_claim_splitsProRata() public {
        _mint(alice, SHARES);
        _mint(bob, SHARES * 2);
        _deposit(INCOME);

        _assertOwed(dist.claimable(alice), INCOME / 3, "alice holds a third");
        _assertOwed(dist.claimable(bob), (INCOME * 2) / 3, "bob holds two thirds");
    }

    function test_claim_canPayADifferentAddress() public {
        _mint(alice, SHARES);
        _deposit(INCOME);

        uint256 owed = dist.claimable(alice);

        vm.prank(alice);
        dist.claim(carol);

        assertEq(currency.balanceOf(carol), owed);
        assertEq(currency.balanceOf(alice), 0);
    }

    function test_claim_revertsOnZeroRecipient() public {
        _mint(alice, SHARES);
        _deposit(INCOME);

        vm.prank(alice);
        vm.expectRevert(IDividendDistributor.ZeroAddress.selector);
        dist.claim(address(0));
    }

    /// @dev A fully frozen holder is refused, whatever they are owed.
    function test_claim_revertsWhileFullyFrozen() public {
        _mint(alice, SHARES);
        _deposit(INCOME);
        token.setFrozen(alice, true);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IDividendDistributor.ClaimantFrozen.selector, alice));
        dist.claim(alice);
    }

    /// @dev A holder the registry does not verify is refused.
    function test_claim_revertsWhileUnverified() public {
        _mint(alice, SHARES);
        _deposit(INCOME);
        token.setVerified(alice, false);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IDividendDistributor.ClaimantNotVerified.selector, alice));
        dist.claim(alice);
    }

    /// @dev Blocking withholds the payout, not the accrual: a deposit made while blocked is owed
    ///      in full once the block is lifted.
    function test_claim_entitlementAccruesWhileBlocked() public {
        _mint(alice, SHARES);
        token.setFrozen(alice, true);
        token.setVerified(alice, false);
        _deposit(INCOME);
        _deposit(INCOME);

        token.setFrozen(alice, false);
        token.setVerified(alice, true);
        uint256 owed = dist.claimable(alice);
        _assertOwed(owed, INCOME * 2, "blocked holder lost accrued income");

        vm.prank(alice);
        dist.claim(alice);
        assertEq(currency.balanceOf(alice), owed);
    }

    function test_claim_revertsWhenNothingAccrued() public {
        _mint(alice, SHARES);
        _deposit(INCOME);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IDividendDistributor.NothingToClaim.selector, bob));
        dist.claim(bob);
    }

    function test_claim_revertsOnSecondClaimWithoutNewIncome() public {
        _mint(alice, SHARES);
        _deposit(INCOME);

        vm.startPrank(alice);
        dist.claim(alice);
        vm.expectRevert(abi.encodeWithSelector(IDividendDistributor.NothingToClaim.selector, alice));
        dist.claim(alice);
        vm.stopPrank();
    }

    function test_claim_accruesAgainAfterASecondDeposit() public {
        _mint(alice, SHARES);
        _deposit(INCOME);

        vm.prank(alice);
        dist.claim(alice);

        _deposit(INCOME);

        _assertOwed(dist.accumulated(alice), INCOME * 2, "two deposits, one holder");
    }

    /// @dev The shortfall against the deposits stays at the single final floor in `accumulated`
    ///      instead of growing with each deposit, and the carried remainder stays below one share.
    ///      At this supply the remainder is worth far less than one wei, so this test does not
    ///      depend on carrying it; the next test does.
    function test_deposit_carriesResidueSoTheShortfallDoesNotGrow() public {
        _mint(alice, SHARES);

        for (uint256 i = 1; i <= 8; ++i) {
            _deposit(INCOME);
            _assertOwed(dist.claimable(alice), INCOME * i, "shortfall drifted beyond one wei");
            assertLt(dist.residue(), token.totalSupply(), "residue must stay below one full share");
        }
    }

    /**
     * @dev What `_residue` is for. Each deposit adds `amount * 2^128 / supply` to the scaled
     *      accumulator and carries the division remainder into the next deposit. With a supply
     *      above 2^128 base units, a deposit of one currency unit is smaller than one scaled unit
     *      per share: on its own it moves the accumulator by zero, and only the carried remainder
     *      lets three such deposits add up to a movement. Without the carry the holder would be
     *      owed nothing however many deposits arrived.
     *
     *      Supply is 2^129 + 1 (odd, so no deposit divides evenly). Three deposits of one unit give
     *      a scaled total of 3 * 2^128, which crosses the supply once, so the accumulator moves by
     *      one and the sole holder is owed floor((2^129 + 1) / 2^128) = 2 of the 3 units.
     */
    function test_deposit_residueCarriesSubUnitRemainderIntoLaterDeposits() public {
        uint256 supply = 2 ** 129 + 1;
        _mint(alice, supply);
        currency.mint(issuer, 3);

        _deposit(1);
        _deposit(1);
        assertEq(dist.dividendsPerShare(), 0, "two unit deposits should not yet move the accumulator");
        assertEq(dist.residue(), 2 ** 129, "the remainder of both deposits must be carried");

        _deposit(1);
        assertEq(dist.dividendsPerShare(), 1);
        assertEq(dist.claimable(alice), 2);
        assertLt(dist.residue(), supply);
    }

    /// @dev Regression: carrying the residue in currency units rounded the dust up every deposit,
    ///      so claims outgrew deposits and the contract went insolvent by a wei per deposit. The
    ///      sum of claims must never exceed the sum of funds received, at any depth.
    function test_deposit_claimsNeverExceedFundsAcrossManyDeposits() public {
        _mint(alice, SHARES);
        _mint(bob, SHARES / 3);

        for (uint256 i = 0; i < 12; ++i) {
            _deposit(INCOME);

            uint256 owed = dist.claimable(alice) + dist.claimable(bob) + dist.withdrawn(alice) + dist.withdrawn(bob);
            assertLe(owed, INCOME * (i + 1), "entitlement exceeded the funds deposited");
        }

        // Both holders must actually be payable, which is the property solvency exists to protect.
        vm.prank(alice);
        dist.claim(alice);
        vm.prank(bob);
        dist.claim(bob);
    }

    /*//////////////////////////////////////////////////////////////
                          CORRECTION ACCOUNTING
    //////////////////////////////////////////////////////////////*/

    /// @dev The property the whole design rests on: a transfer moves shares, never entitlement.
    function test_transfer_doesNotMoveAlreadyAccruedDividends() public {
        _mint(alice, SHARES);
        _deposit(INCOME);

        _transfer(alice, bob, SHARES);

        _assertOwed(dist.claimable(alice), INCOME, "seller keeps what accrued while holding");
        assertEq(dist.claimable(bob), 0, "buyer is not paid for income before they arrived");
    }

    /// @dev The buyer earns from the next deposit, the seller does not.
    function test_transfer_shiftsFutureIncomeToTheBuyer() public {
        _mint(alice, SHARES);
        _deposit(INCOME);
        _transfer(alice, bob, SHARES);
        _deposit(INCOME);

        _assertOwed(dist.claimable(alice), INCOME, "seller keeps the first deposit only");
        _assertOwed(dist.claimable(bob), INCOME, "buyer earns the second deposit only");
    }

    function test_transfer_partialBalanceSplitsFutureIncome() public {
        _mint(alice, SHARES);
        _transfer(alice, bob, SHARES / 2);
        _deposit(INCOME);

        _assertOwed(dist.claimable(alice), INCOME / 2, "alice holds half");
        _assertOwed(dist.claimable(bob), INCOME / 2, "bob holds half");
    }

    /// @dev Claiming and then selling must not let the seller be paid twice for the same income.
    function test_transfer_afterClaimLeavesNothingToDoubleClaim() public {
        _mint(alice, SHARES);
        _deposit(INCOME);

        uint256 paid = dist.claimable(alice);
        vm.prank(alice);
        dist.claim(alice);

        _transfer(alice, bob, SHARES);

        assertEq(dist.claimable(alice), 0);
        assertEq(dist.claimable(bob), 0);
        assertEq(currency.balanceOf(alice), paid);
    }

    /// @dev A self-transfer must be inert. The same inference inflated MaxHoldersModule's count.
    function test_transfer_selfTransferDoesNotChangeEntitlement() public {
        _mint(alice, SHARES);
        _deposit(INCOME);

        _transfer(alice, alice, SHARES);

        _assertOwed(dist.claimable(alice), INCOME, "self-transfer changed entitlement");
    }

    function test_transfer_selfTransferBeforeIncomeIsInert() public {
        _mint(alice, SHARES);
        _transfer(alice, alice, SHARES);
        _deposit(INCOME);

        _assertOwed(dist.claimable(alice), INCOME, "self-transfer changed entitlement");
    }

    /// @dev A late arrival must not be retroactively paid for income deposited before them.
    function test_mint_afterIncomeGrantsNoBackpay() public {
        _mint(alice, SHARES);
        _deposit(INCOME);

        _mint(bob, SHARES);

        assertEq(dist.claimable(bob), 0);
        _assertOwed(dist.claimable(alice), INCOME, "existing holder keeps the earlier deposit");
    }

    /// @dev Burning shares must not burn dividends already earned by them.
    function test_burn_preservesAccruedDividends() public {
        _mint(alice, SHARES);
        _deposit(INCOME);

        _burn(alice, SHARES);

        uint256 owed = dist.claimable(alice);
        _assertOwed(owed, INCOME, "burning shares must not burn earned income");

        vm.prank(alice);
        dist.claim(alice);
        assertEq(currency.balanceOf(alice), owed);
    }

    function test_burn_stopsFutureAccrual() public {
        _mint(alice, SHARES);
        _mint(bob, SHARES);
        _burn(alice, SHARES);
        _deposit(INCOME);

        assertEq(dist.claimable(alice), 0);
        _assertOwed(dist.claimable(bob), INCOME, "remaining holder takes the whole deposit");
    }

    /*//////////////////////////////////////////////////////////////
                                RECOVERY
    //////////////////////////////////////////////////////////////*/

    /// @dev Recovery relocates the position whole. Settling it as a sale would leave the income on
    ///      the compromised wallet, which is exactly what recovery exists to prevent.
    function test_recovery_carriesEntitlementToTheNewWallet() public {
        _mint(alice, SHARES);
        _deposit(INCOME);

        uint256 owed = dist.claimable(alice);
        assertGt(owed, 0);

        token.setRecovering(true);
        _transfer(alice, bob, SHARES);
        token.setRecovering(false);

        assertEq(dist.claimable(alice), 0, "the lost wallet must be left owed nothing");
        assertEq(dist.claimable(bob), owed, "the income followed the position");
    }

    /// @dev The attack the recovery branch closes: without it, whoever holds the compromised
    ///      wallet's keys can still withdraw the income after the tokens have been rescued.
    function test_recovery_lostWalletCannotClaimAfterwards() public {
        _mint(alice, SHARES);
        _deposit(INCOME);

        token.setRecovering(true);
        _transfer(alice, bob, SHARES);
        token.setRecovering(false);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IDividendDistributor.NothingToClaim.selector, alice));
        dist.claim(alice);
    }

    /// @dev Already-withdrawn income must carry too, or the new wallet could re-claim what the old
    ///      one was legitimately paid before the incident.
    function test_recovery_carriesTheWithdrawalRecord() public {
        _mint(alice, SHARES);
        _deposit(INCOME);

        vm.prank(alice);
        dist.claim(alice);
        uint256 paid = dist.withdrawn(alice);

        token.setRecovering(true);
        _transfer(alice, bob, SHARES);
        token.setRecovering(false);

        assertEq(dist.withdrawn(bob), paid, "the withdrawal record moved with the position");
        assertEq(dist.claimable(bob), 0, "recovery must not re-open a settled claim");
        assertEq(dist.withdrawn(alice), 0);
    }

    /// @dev After recovery the new wallet must accrue normally, as the position's only owner.
    function test_recovery_newWalletAccruesFutureIncome() public {
        _mint(alice, SHARES);

        token.setRecovering(true);
        _transfer(alice, bob, SHARES);
        token.setRecovering(false);

        _deposit(INCOME);

        assertEq(dist.claimable(alice), 0);
        _assertOwed(dist.claimable(bob), INCOME, "recovered wallet earns the whole deposit");
    }

    /*//////////////////////////////////////////////////////////////
                                 CHECK
    //////////////////////////////////////////////////////////////*/

    /// @dev The distributor observes transfers, it never blocks one.
    function test_moduleCheck_alwaysPermits() public view {
        assertTrue(dist.moduleCheck(alice, bob, SHARES));
        assertTrue(dist.moduleCheck(address(0), bob, SHARES));
        assertTrue(dist.moduleCheck(alice, address(0), SHARES));
        assertTrue(dist.moduleCheck(address(0), address(0), 0));
    }

    /*//////////////////////////////////////////////////////////////
                             HOOK ACCESS
    //////////////////////////////////////////////////////////////*/

    function test_moduleTransferred_revertsForNonCompliance() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IComplianceModule.OnlyCompliance.selector, alice, engine));
        dist.moduleTransferred(alice, bob, SHARES);
    }

    function test_moduleCreated_revertsForNonCompliance() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IComplianceModule.OnlyCompliance.selector, alice, engine));
        dist.moduleCreated(alice, SHARES);
    }

    function test_moduleDestroyed_revertsForNonCompliance() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IComplianceModule.OnlyCompliance.selector, alice, engine));
        dist.moduleDestroyed(alice, SHARES);
    }

    /*//////////////////////////////////////////////////////////////
                             REENTRANCY
    //////////////////////////////////////////////////////////////*/

    /// @dev Deploys a distributor over a currency that reenters it, funds the issuer and gives the
    ///      currency contract itself a position, so it has something to claim.
    function _hostileSetup() internal returns (ReenteringCurrency evil, DividendDistributor target) {
        evil = new ReenteringCurrency();
        target = new DividendDistributor(engine, address(token), address(evil), issuer);
        vm.prank(engine);
        target.bindCompliance(engine);

        evil.mint(issuer, 10_000e6);
        vm.prank(issuer);
        evil.approve(address(target), type(uint256).max);

        token.mint(address(evil), SHARES);
        vm.prank(engine);
        target.moduleCreated(address(evil), SHARES);
    }

    /**
     * @dev A settlement currency that reenters `claim` from inside its own `transfer`. The reentry
     *      is attempted (the flag proves it), the guard rejects it with its own error, and the
     *      outer claim still pays exactly once.
     *
     *      The guard is the first line here, not the only one: `claim` records the withdrawal
     *      before paying, so even without the guard the reentrant call would find nothing left to
     *      claim and revert with `NothingToClaim`.
     */
    function test_claim_isReentrancyGuarded() public {
        (ReenteringCurrency evil, DividendDistributor target) = _hostileSetup();
        vm.prank(issuer);
        target.deposit(INCOME);
        uint256 owed = target.claimable(address(evil));

        evil.arm(address(target), abi.encodeCall(DividendDistributor.claim, (address(evil))), false);
        vm.prank(address(evil));
        target.claim(address(evil));

        assertTrue(evil.reentryAttempted(), "the currency never reentered");
        assertFalse(evil.reentrySucceeded(), "the reentrant claim went through");
        assertEq(bytes4(evil.reentryError()), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(evil.balanceOf(address(evil)), owed, "paid more or less than once");
        assertEq(target.claimable(address(evil)), 0);
    }

    /**
     * @dev A settlement currency that reenters `deposit` from inside the `transferFrom` that pulls
     *      the funds. The currency is given `AGENT_ROLE`, so only the guard can stop it: the reentry
     *      is attempted, rejected with the guard's error, and the outer deposit is counted once.
     */
    function test_deposit_isReentrancyGuarded() public {
        (ReenteringCurrency evil, DividendDistributor target) = _hostileSetup();
        bytes32 agentRole = Roles.AGENT_ROLE;
        vm.prank(issuer);
        target.grantRole(agentRole, address(evil));
        evil.mint(address(evil), INCOME);
        vm.prank(address(evil));
        evil.approve(address(target), type(uint256).max);

        evil.arm(address(target), abi.encodeCall(DividendDistributor.deposit, (INCOME)), true);
        vm.prank(issuer);
        target.deposit(INCOME);

        assertTrue(evil.reentryAttempted(), "the currency never reentered");
        assertFalse(evil.reentrySucceeded(), "the reentrant deposit went through");
        assertEq(bytes4(evil.reentryError()), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(evil.balanceOf(address(target)), INCOME, "deposit counted more than once");
        _assertOwed(target.claimable(address(evil)), INCOME, "accumulator moved more than once");
    }

    /*//////////////////////////////////////////////////////////////
                                 FUZZ
    //////////////////////////////////////////////////////////////*/

    /// @dev No holder may ever claim more than the contract was funded with.
    function testFuzz_conservation_claimsNeverExceedDeposits(uint256 aliceShares, uint256 bobShares, uint256 income)
        public
    {
        aliceShares = bound(aliceShares, 1, 1e30);
        bobShares = bound(bobShares, 1, 1e30);
        income = bound(income, 1, 1e18);

        _mint(alice, aliceShares);
        _mint(bob, bobShares);

        currency.mint(issuer, income);
        _deposit(income);

        uint256 total = dist.claimable(alice) + dist.claimable(bob);
        assertLe(total, income, "distributed more than deposited");
    }

    /// @dev Rounding dust is bounded: it is the residue of one division per holder, not a leak.
    function testFuzz_roundingDustIsBounded(uint256 aliceShares, uint256 bobShares, uint256 income) public {
        aliceShares = bound(aliceShares, 1, 1e30);
        bobShares = bound(bobShares, 1, 1e30);
        income = bound(income, 1, 1e18);

        _mint(alice, aliceShares);
        _mint(bob, bobShares);

        currency.mint(issuer, income);
        _deposit(income);

        uint256 total = dist.claimable(alice) + dist.claimable(bob);
        assertGe(total + 2, income, "dust exceeded one wei per holder");
    }

    /// @dev Entitlement is invariant under transfer, whatever the split.
    function testFuzz_transferPreservesTotalEntitlement(uint256 shares, uint256 income, uint256 sendPart) public {
        shares = bound(shares, 2, 1e30);
        income = bound(income, 1, 1e18);
        sendPart = bound(sendPart, 1, shares);

        _mint(alice, shares);
        currency.mint(issuer, income);
        _deposit(income);

        uint256 before = dist.claimable(alice) + dist.claimable(bob);
        _transfer(alice, bob, sendPart);
        uint256 afterTransfer = dist.claimable(alice) + dist.claimable(bob);

        assertEq(afterTransfer, before, "a transfer created or destroyed entitlement");
    }

    /// @dev Solvency under repeated deposits, the case the currency-unit residue broke. The
    ///      contract must always hold enough to pay everything it says is owed, and must not leak
    ///      value to rounding as deposits accumulate.
    function testFuzz_solventAcrossRepeatedDeposits(
        uint256 aliceShares,
        uint256 bobShares,
        uint256 income,
        uint8 rounds
    ) public {
        aliceShares = bound(aliceShares, 1, 1e30);
        bobShares = bound(bobShares, 1, 1e30);
        income = bound(income, 1, 1e18);
        rounds = uint8(bound(rounds, 1, 20));

        _mint(alice, aliceShares);
        _mint(bob, bobShares);

        for (uint256 i = 0; i < rounds; ++i) {
            currency.mint(issuer, income);
            _deposit(income);
        }

        uint256 owed = dist.claimable(alice) + dist.claimable(bob);
        assertLe(owed, currency.balanceOf(address(dist)), "owed more than the contract holds");

        // Lower bound: the holders together fall short of everything deposited by at most two wei,
        // however many deposits there were. Each deposit's own truncation is carried in the scaled
        // residue, so the unpaid remainder never reaches a whole unit; the only loss is the final
        // floor in each holder's `accumulated`, under one wei per holder. A shortfall that grew
        // with the number of deposits would mean the residue leaks.
        assertGe(owed + 2, income * rounds, "holders lost more than the per-holder rounding");
    }

    /// @dev Every claim must be payable: the contract must hold what it says is claimable.
    function testFuzz_claimIsAlwaysSolvent(uint256 shares, uint256 income, uint256 sendPart) public {
        shares = bound(shares, 2, 1e30);
        income = bound(income, 1, 1e18);
        sendPart = bound(sendPart, 1, shares);

        _mint(alice, shares);
        currency.mint(issuer, income);
        _deposit(income);
        _transfer(alice, bob, sendPart);

        uint256 owedAlice = dist.claimable(alice);
        if (owedAlice != 0) {
            vm.prank(alice);
            dist.claim(alice);
            assertEq(currency.balanceOf(alice), owedAlice);
        }

        uint256 owedBob = dist.claimable(bob);
        if (owedBob != 0) {
            vm.prank(bob);
            dist.claim(bob);
            assertEq(currency.balanceOf(bob), owedBob);
        }
    }
}

/**
 * @notice A settlement currency that reenters its distributor while moving funds.
 * @dev Models the hostile case for a contract that pays out or pulls in an external token: the
 *      currency gets control in the middle of `claim` (inside `transfer`) or `deposit` (inside
 *      `transferFrom`). Once armed, it makes one reentrant call, records that it tried and how the
 *      call ended, and then completes the transfer, so the outer call's own result stays visible.
 */
contract ReenteringCurrency is MockCurrency {
    address public target;
    bytes public reentryCall;
    bool public onTransferFrom;

    bool public reentryAttempted;
    bool public reentrySucceeded;
    bytes public reentryError;

    function arm(address target_, bytes calldata call_, bool onTransferFrom_) external {
        target = target_;
        reentryCall = call_;
        onTransferFrom = onTransferFrom_;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (!onTransferFrom) _reenter();
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (onTransferFrom) _reenter();
        return super.transferFrom(from, to, amount);
    }

    function _reenter() internal {
        if (target == address(0) || reentryAttempted) return;
        reentryAttempted = true;
        (bool ok, bytes memory ret) = target.call(reentryCall);
        reentrySucceeded = ok;
        if (!ok) reentryError = ret;
    }
}
