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
    MockRecoverableToken internal token;
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
        token = new MockRecoverableToken();
        currency = new MockCurrency();
        dist = new DividendDistributor(engine, address(token), address(currency), issuer);

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

    /// @dev The remainder a deposit cannot represent is carried in scaled units, so the shortfall
    ///      stays pinned at the single final truncation instead of growing with each deposit.
    function test_deposit_carriesResidueSoTheShortfallDoesNotGrow() public {
        _mint(alice, SHARES);

        for (uint256 i = 1; i <= 8; ++i) {
            _deposit(INCOME);
            assertEq(dist.claimable(alice), INCOME * i - 1, "shortfall drifted beyond one wei");
            assertLt(dist.residue(), token.totalSupply(), "residue must stay below one full share");
        }
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

    /// @dev A malicious settlement currency must not be able to reenter claim and be paid twice.
    function test_claim_isReentrancyGuarded() public {
        ReenteringCurrency evil = new ReenteringCurrency();
        DividendDistributor target = new DividendDistributor(engine, address(token), address(evil), issuer);

        evil.mint(issuer, 1_000e6);
        vm.prank(issuer);
        evil.approve(address(target), type(uint256).max);

        token.mint(address(evil), SHARES);
        vm.prank(engine);
        target.moduleCreated(address(evil), SHARES);

        vm.prank(issuer);
        target.deposit(INCOME);

        evil.setTarget(target);

        // The currency reenters claim from inside its own transfer. The guard must reject it,
        // which surfaces as the whole outer claim reverting.
        vm.prank(address(evil));
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        target.claim(address(evil));
    }

    /*//////////////////////////////////////////////////////////////
                                 FUZZ
    //////////////////////////////////////////////////////////////*/

    /// @dev No holder may ever claim more than the contract was funded with.
    function testFuzz_conservation_claimsNeverExceedDeposits(uint96 aliceShares, uint96 bobShares, uint96 income)
        public
    {
        aliceShares = uint96(bound(aliceShares, 1e18, 1e30));
        bobShares = uint96(bound(bobShares, 1e18, 1e30));
        income = uint96(bound(income, 1e6, 1e18));

        _mint(alice, aliceShares);
        _mint(bob, bobShares);

        currency.mint(issuer, income);
        _deposit(income);

        uint256 total = dist.claimable(alice) + dist.claimable(bob);
        assertLe(total, income, "distributed more than deposited");
    }

    /// @dev Rounding dust is bounded: it is the residue of one division per holder, not a leak.
    function testFuzz_roundingDustIsBounded(uint96 aliceShares, uint96 bobShares, uint96 income) public {
        aliceShares = uint96(bound(aliceShares, 1e18, 1e30));
        bobShares = uint96(bound(bobShares, 1e18, 1e30));
        income = uint96(bound(income, 1e6, 1e18));

        _mint(alice, aliceShares);
        _mint(bob, bobShares);

        currency.mint(issuer, income);
        _deposit(income);

        uint256 total = dist.claimable(alice) + dist.claimable(bob);
        assertGe(total + 2, income, "dust exceeded one wei per holder");
    }

    /// @dev Entitlement is invariant under transfer, whatever the split.
    function testFuzz_transferPreservesTotalEntitlement(uint96 shares, uint96 income, uint96 sendPart) public {
        shares = uint96(bound(shares, 2e18, 1e30));
        income = uint96(bound(income, 1e6, 1e18));
        sendPart = uint96(bound(sendPart, 1, shares));

        _mint(alice, shares);
        currency.mint(issuer, income);
        _deposit(income);

        uint256 before = dist.claimable(alice) + dist.claimable(bob);
        _transfer(alice, bob, sendPart);
        uint256 afterTransfer = dist.claimable(alice) + dist.claimable(bob);

        assertEq(afterTransfer, before, "a transfer created or destroyed entitlement");
    }

    /// @dev Solvency under repeated deposits, the case the currency-unit residue broke. The
    ///      contract must always hold enough to pay everything it says is owed.
    function testFuzz_solventAcrossRepeatedDeposits(uint96 aliceShares, uint96 bobShares, uint96 income, uint8 rounds)
        public
    {
        aliceShares = uint96(bound(aliceShares, 1e18, 1e30));
        bobShares = uint96(bound(bobShares, 1e18, 1e30));
        income = uint96(bound(income, 1e6, 1e18));
        rounds = uint8(bound(rounds, 1, 20));

        _mint(alice, aliceShares);
        _mint(bob, bobShares);

        for (uint256 i = 0; i < rounds; ++i) {
            currency.mint(issuer, income);
            _deposit(income);
        }

        uint256 owed = dist.claimable(alice) + dist.claimable(bob);
        assertLe(owed, currency.balanceOf(address(dist)), "owed more than the contract holds");
    }

    /// @dev Every claim must be payable: the contract must hold what it says is claimable.
    function testFuzz_claimIsAlwaysSolvent(uint96 shares, uint96 income, uint96 sendPart) public {
        shares = uint96(bound(shares, 2e18, 1e30));
        income = uint96(bound(income, 1e6, 1e18));
        sendPart = uint96(bound(sendPart, 1, shares));

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
 * @notice A MockToken that can report itself as mid forced recovery.
 * @dev The distributor asks the token whether a transfer is a recovery, which a plain ERC-20
 *      cannot answer. Only the flag is modelled here, not the recovery logic: the real interaction
 *      with `SecurityToken.forcedRecovery` is covered end to end in the scenario suite.
 */
contract MockRecoverableToken is MockToken {
    bool public recovering;

    function setRecovering(bool value) external {
        recovering = value;
    }
}

/**
 * @notice A settlement currency that reenters claim from inside its own transfer.
 * @dev Models the realistic hostile case for a pull-payment contract: the currency is an external
 *      contract, and a token with a transfer callback (or an outright malicious one) gets control
 *      after the withdrawal is recorded. Only the guard stands between that and a double payout.
 */
contract ReenteringCurrency is MockCurrency {
    DividendDistributor internal _target;

    function setTarget(DividendDistributor target_) external {
        _target = target_;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (address(_target) != address(0)) {
            _target.claim(to);
        }
        return super.transfer(to, amount);
    }
}
