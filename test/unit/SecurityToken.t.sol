// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {SecurityToken} from "../../src/SecurityToken.sol";
import {ISecurityToken} from "../../src/interfaces/ISecurityToken.sol";
import {IdentityRegistry} from "../../src/identity/IdentityRegistry.sol";
import {ModularCompliance} from "../../src/compliance/ModularCompliance.sol";
import {Roles} from "../../src/Roles.sol";
import {MockModule} from "../helpers/MockModule.sol";

contract SecurityTokenTest is Test {
    SecurityToken internal token;
    IdentityRegistry internal registry;
    ModularCompliance internal compliance;
    MockModule internal module;

    address internal issuer = makeAddr("issuer");
    address internal agent = makeAddr("agent");
    address internal custodian = makeAddr("custodian");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal attacker = makeAddr("attacker");
    /// @dev A second wallet of the same investor as alice, the only valid recovery destination for her.
    address internal aliceSecondary = makeAddr("aliceSecondary");

    uint16 internal constant COUNTRY = 724; // Spain
    uint64 internal kycExpiry;
    uint256 internal constant AMOUNT = 1_000e18;

    function setUp() public {
        kycExpiry = uint64(block.timestamp + 365 days);

        registry = new IdentityRegistry(issuer, agent);
        compliance = new ModularCompliance(issuer);
        token = new SecurityToken("Real Estate Note", "RENOTE", issuer, address(registry), address(compliance));

        // A pass-through module so the modular layer is real but controllable.
        module = new MockModule(address(compliance), "MockModule");

        vm.startPrank(issuer);
        compliance.addModule(address(module));
        compliance.bindToken(address(token));
        token.grantRole(Roles.AGENT_ROLE, agent);
        token.grantRole(Roles.CUSTODIAN_ROLE, custodian);
        // Recovery evicts the lost wallet from the registry, so the token acts as an agent there.
        registry.grantRole(Roles.AGENT_ROLE, address(token));
        vm.stopPrank();

        _verify(alice);
        _verify(bob);
        _verify(carol);
        _verifyAs(aliceSecondary, _idOf(alice));
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _verify(address who) internal {
        vm.prank(agent);
        registry.registerIdentity(who, COUNTRY, false, kycExpiry);
    }

    /// @dev Registers a wallet under an existing investor id, linking it to that investor's other wallets.
    function _verifyAs(address who, bytes32 id) internal {
        vm.prank(agent);
        registry.registerIdentity(who, COUNTRY, false, kycExpiry, id);
    }

    function _idOf(address who) internal view returns (bytes32) {
        return registry.investorId(who);
    }

    function _mint(address to, uint256 amount) internal {
        vm.prank(issuer);
        token.mint(to, amount);
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    function test_constructor_setsState() public view {
        assertEq(token.name(), "Real Estate Note");
        assertEq(token.symbol(), "RENOTE");
        assertEq(token.identityRegistry(), address(registry));
        assertEq(token.compliance(), address(compliance));
        assertTrue(token.hasRole(token.DEFAULT_ADMIN_ROLE(), issuer));
    }

    function test_constructor_revertsOnZeroIssuer() public {
        vm.expectRevert(ISecurityToken.ZeroAddress.selector);
        new SecurityToken("N", "N", address(0), address(registry), address(compliance));
    }

    function test_constructor_revertsOnZeroRegistry() public {
        vm.expectRevert(ISecurityToken.ZeroAddress.selector);
        new SecurityToken("N", "N", issuer, address(0), address(compliance));
    }

    function test_constructor_revertsOnZeroCompliance() public {
        vm.expectRevert(ISecurityToken.ZeroAddress.selector);
        new SecurityToken("N", "N", issuer, address(registry), address(0));
    }

    /*//////////////////////////////////////////////////////////////
                                 MINT
    //////////////////////////////////////////////////////////////*/

    function test_mint_creditsVerifiedRecipient() public {
        _mint(alice, AMOUNT);

        assertEq(token.balanceOf(alice), AMOUNT);
        assertEq(token.totalSupply(), AMOUNT);
    }

    function test_mint_firesCreatedHook() public {
        _mint(alice, AMOUNT);

        assertEq(module.createdCount(), 1);
        assertEq(module.lastTo(), alice);
        assertEq(module.lastAmount(), AMOUNT);
    }

    function test_mint_revertsForNonIssuer() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, token.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(attacker);
        token.mint(alice, AMOUNT);
    }

    /// @dev A mint routes through the same recipient gate a transfer does.
    function test_mint_revertsForUnverifiedRecipient() public {
        address stranger = makeAddr("stranger");
        vm.expectRevert(abi.encodeWithSelector(ISecurityToken.RecipientNotVerified.selector, stranger));
        _mint(stranger, AMOUNT);
    }

    function test_mint_revertsWhenComplianceRejects() public {
        module.setAllow(false);
        vm.expectRevert(
            abi.encodeWithSelector(ISecurityToken.ComplianceCheckFailed.selector, address(0), alice, AMOUNT)
        );
        _mint(alice, AMOUNT);
    }

    /*//////////////////////////////////////////////////////////////
                                 BURN
    //////////////////////////////////////////////////////////////*/

    function test_burn_reducesBalanceAndSupply() public {
        _mint(alice, AMOUNT);

        vm.prank(issuer);
        token.burn(alice, AMOUNT / 4);

        assertEq(token.balanceOf(alice), AMOUNT - AMOUNT / 4);
        assertEq(token.totalSupply(), AMOUNT - AMOUNT / 4);
    }

    function test_burn_firesDestroyedHook() public {
        _mint(alice, AMOUNT);

        vm.prank(issuer);
        token.burn(alice, AMOUNT / 4);

        assertEq(module.destroyedCount(), 1);
    }

    function test_burn_revertsForNonIssuer() public {
        _mint(alice, AMOUNT);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, token.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(attacker);
        token.burn(alice, AMOUNT);
    }

    /// @dev Burning only the unfrozen part leaves the frozen portion intact.
    function test_burn_belowFreeLeavesFrozenIntact() public {
        _mint(alice, AMOUNT);
        vm.prank(agent);
        token.freezePartialTokens(alice, AMOUNT / 2);

        vm.prank(issuer);
        token.burn(alice, AMOUNT / 4);

        assertEq(token.frozenTokens(alice), AMOUNT / 2);
        assertEq(token.balanceOf(alice), AMOUNT - AMOUNT / 4);
    }

    /// @dev A burn larger than the free balance reduces the frozen portion to cover the shortfall:
    ///      the issuer outranks an operational freeze.
    function test_burn_eatsFrozenWhenExceedingFree() public {
        _mint(alice, AMOUNT);
        vm.prank(agent);
        token.freezePartialTokens(alice, AMOUNT); // whole balance frozen

        vm.expectEmit(true, false, false, true, address(token));
        emit ISecurityToken.TokensUnfrozen(alice, AMOUNT / 4);

        vm.prank(issuer);
        token.burn(alice, AMOUNT / 4);

        assertEq(token.frozenTokens(alice), AMOUNT - AMOUNT / 4);
        assertEq(token.balanceOf(alice), AMOUNT - AMOUNT / 4);
    }

    /*//////////////////////////////////////////////////////////////
                            FREEZE CONTROLS
    //////////////////////////////////////////////////////////////*/

    function test_setAddressFrozen_togglesAndEmits() public {
        vm.expectEmit(true, false, false, true, address(token));
        emit ISecurityToken.AddressFrozen(alice, true);

        vm.prank(agent);
        token.setAddressFrozen(alice, true);
        assertTrue(token.isFrozen(alice));

        vm.prank(agent);
        token.setAddressFrozen(alice, false);
        assertFalse(token.isFrozen(alice));
    }

    function test_setAddressFrozen_revertsForNonAgent() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, Roles.AGENT_ROLE)
        );
        vm.prank(attacker);
        token.setAddressFrozen(alice, true);
    }

    function test_freezePartialTokens_accumulatesAndEmits() public {
        _mint(alice, AMOUNT);

        vm.expectEmit(true, false, false, true, address(token));
        emit ISecurityToken.TokensFrozen(alice, AMOUNT / 4);

        vm.prank(agent);
        token.freezePartialTokens(alice, AMOUNT / 4);
        assertEq(token.frozenTokens(alice), AMOUNT / 4);

        vm.prank(agent);
        token.freezePartialTokens(alice, AMOUNT / 4);
        assertEq(token.frozenTokens(alice), AMOUNT / 2);
    }

    function test_freezePartialTokens_revertsAboveBalance() public {
        _mint(alice, AMOUNT);
        vm.expectRevert(
            abi.encodeWithSelector(ISecurityToken.FreezeAmountExceedsBalance.selector, alice, AMOUNT, AMOUNT + 1)
        );
        vm.prank(agent);
        token.freezePartialTokens(alice, AMOUNT + 1);
    }

    function test_unfreezePartialTokens_reducesAndEmits() public {
        _mint(alice, AMOUNT);
        vm.prank(agent);
        token.freezePartialTokens(alice, AMOUNT / 2);

        vm.expectEmit(true, false, false, true, address(token));
        emit ISecurityToken.TokensUnfrozen(alice, AMOUNT / 4);

        vm.prank(agent);
        token.unfreezePartialTokens(alice, AMOUNT / 4);
        assertEq(token.frozenTokens(alice), AMOUNT / 4);
    }

    function test_unfreezePartialTokens_revertsAboveFrozen() public {
        _mint(alice, AMOUNT);
        vm.prank(agent);
        token.freezePartialTokens(alice, AMOUNT / 4);

        vm.expectRevert(
            abi.encodeWithSelector(ISecurityToken.UnfreezeAmountExceedsFrozen.selector, alice, AMOUNT / 4, AMOUNT / 2)
        );
        vm.prank(agent);
        token.unfreezePartialTokens(alice, AMOUNT / 2);
    }

    /*//////////////////////////////////////////////////////////////
                             TRANSFER GATE
    //////////////////////////////////////////////////////////////*/

    function test_transfer_succeedsBetweenVerified() public {
        _mint(alice, AMOUNT);

        vm.prank(alice);
        token.transfer(bob, AMOUNT / 2);

        assertEq(token.balanceOf(alice), AMOUNT / 2);
        assertEq(token.balanceOf(bob), AMOUNT / 2);
        assertEq(module.transferredCount(), 1);
    }

    function test_transfer_revertsForUnverifiedRecipient() public {
        _mint(alice, AMOUNT);
        address stranger = makeAddr("stranger");

        vm.expectRevert(abi.encodeWithSelector(ISecurityToken.RecipientNotVerified.selector, stranger));
        vm.prank(alice);
        token.transfer(stranger, AMOUNT);
    }

    function test_transfer_revertsWhenRecipientFrozen() public {
        _mint(alice, AMOUNT);
        vm.prank(agent);
        token.setAddressFrozen(bob, true);

        vm.expectRevert(abi.encodeWithSelector(ISecurityToken.RecipientAddressFrozen.selector, bob));
        vm.prank(alice);
        token.transfer(bob, AMOUNT);
    }

    function test_transfer_revertsWhenSenderFrozen() public {
        _mint(alice, AMOUNT);
        vm.prank(agent);
        token.setAddressFrozen(alice, true);

        vm.expectRevert(abi.encodeWithSelector(ISecurityToken.SenderAddressFrozen.selector, alice));
        vm.prank(alice);
        token.transfer(bob, AMOUNT);
    }

    function test_transfer_revertsWhenExceedingUnfrozen() public {
        _mint(alice, AMOUNT);
        vm.prank(agent);
        token.freezePartialTokens(alice, AMOUNT / 2);

        vm.expectRevert(
            abi.encodeWithSelector(
                ISecurityToken.InsufficientUnfrozenBalance.selector, alice, AMOUNT / 2, AMOUNT / 2 + 1
            )
        );
        vm.prank(alice);
        token.transfer(bob, AMOUNT / 2 + 1);
    }

    /// @dev The unfrozen portion is still fully liquid.
    function test_transfer_movesUnfrozenPortion() public {
        _mint(alice, AMOUNT);
        vm.prank(agent);
        token.freezePartialTokens(alice, AMOUNT / 2);

        vm.prank(alice);
        token.transfer(bob, AMOUNT / 2);

        assertEq(token.balanceOf(bob), AMOUNT / 2);
        assertEq(token.frozenTokens(alice), AMOUNT / 2);
    }

    function test_transfer_revertsWhenComplianceRejects() public {
        _mint(alice, AMOUNT);
        module.setAllow(false);

        vm.expectRevert(abi.encodeWithSelector(ISecurityToken.ComplianceCheckFailed.selector, alice, bob, AMOUNT));
        vm.prank(alice);
        token.transfer(bob, AMOUNT);
    }

    /*//////////////////////////////////////////////////////////////
                                 PAUSE
    //////////////////////////////////////////////////////////////*/

    function test_pause_haltsTransfers() public {
        _mint(alice, AMOUNT);
        vm.prank(agent);
        token.pause();

        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(alice);
        token.transfer(bob, AMOUNT);
    }

    /// @dev Pause is a market-wide stop: it halts mint and burn too, not only transfers.
    function test_pause_haltsMintAndBurn() public {
        vm.prank(agent);
        token.pause();

        vm.expectRevert(Pausable.EnforcedPause.selector);
        _mint(alice, AMOUNT);
    }

    function test_unpause_resumesTransfers() public {
        _mint(alice, AMOUNT);
        vm.prank(agent);
        token.pause();
        vm.prank(agent);
        token.unpause();

        vm.prank(alice);
        token.transfer(bob, AMOUNT);
        assertEq(token.balanceOf(bob), AMOUNT);
    }

    /// @dev Recovery is exempt from the pause: a key compromise is a common reason to halt trading,
    ///      and the affected position must not be stranded until the pause lifts.
    function test_pause_doesNotBlockForcedRecovery() public {
        _mint(alice, AMOUNT);
        vm.prank(agent);
        token.pause();

        vm.prank(custodian);
        token.forcedRecovery(alice, aliceSecondary);

        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(aliceSecondary), AMOUNT);
        assertTrue(token.paused());
    }

    /// @dev The exemption is scoped to the recovery call itself. Once it returns, the pause is
    ///      back in force for everyone, including the wallet that just received the position.
    function test_pause_recoveryExemptionDoesNotOutliveTheCall() public {
        _mint(alice, AMOUNT);
        vm.prank(agent);
        token.pause();

        vm.prank(custodian);
        token.forcedRecovery(alice, aliceSecondary);

        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(aliceSecondary);
        token.transfer(carol, AMOUNT);

        vm.expectRevert(Pausable.EnforcedPause.selector);
        _mint(carol, AMOUNT);
    }

    /// @dev Negative: the exemption does not widen who may recover. Pause is not a bypass of roles.
    function test_pause_recoveryStillRequiresCustodian() public {
        _mint(alice, AMOUNT);
        vm.prank(agent);
        token.pause();

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, Roles.CUSTODIAN_ROLE
            )
        );
        vm.prank(attacker);
        token.forcedRecovery(alice, aliceSecondary);
    }

    /// @dev Negative: nor does it relax the recovery gate itself while paused.
    function test_pause_recoveryStillEnforcesIdentityCheck() public {
        _mint(alice, AMOUNT);
        vm.prank(agent);
        token.pause();

        vm.expectRevert(
            abi.encodeWithSelector(ISecurityToken.RecoveryAcrossInvestors.selector, _idOf(alice), _idOf(bob))
        );
        vm.prank(custodian);
        token.forcedRecovery(alice, bob);
    }

    function test_pause_revertsForNonAgent() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, Roles.AGENT_ROLE)
        );
        vm.prank(attacker);
        token.pause();
    }

    /*//////////////////////////////////////////////////////////////
                             CANTRANSFER VIEW
    //////////////////////////////////////////////////////////////*/

    function test_canTransfer_trueForValidTransfer() public {
        _mint(alice, AMOUNT);
        assertTrue(token.canTransfer(alice, bob, AMOUNT));
    }

    function test_canTransfer_falseForUnverifiedRecipient() public {
        _mint(alice, AMOUNT);
        assertFalse(token.canTransfer(alice, makeAddr("stranger"), AMOUNT));
    }

    function test_canTransfer_falseWhenPaused() public {
        _mint(alice, AMOUNT);
        vm.prank(agent);
        token.pause();

        assertFalse(token.canTransfer(alice, bob, AMOUNT));
    }

    /// @dev The view and the transfer share one gate, so a case the view rejects also reverts.
    function test_canTransfer_agreesWithUpdate() public {
        _mint(alice, AMOUNT);
        vm.prank(agent);
        token.freezePartialTokens(alice, AMOUNT / 2);

        assertFalse(token.canTransfer(alice, bob, AMOUNT));

        vm.expectRevert(
            abi.encodeWithSelector(ISecurityToken.InsufficientUnfrozenBalance.selector, alice, AMOUNT / 2, AMOUNT)
        );
        vm.prank(alice);
        token.transfer(bob, AMOUNT);
    }

    /*//////////////////////////////////////////////////////////////
                                RECOVERY
    //////////////////////////////////////////////////////////////*/

    function test_forcedRecovery_movesFullBalance() public {
        _mint(alice, AMOUNT);

        vm.prank(custodian);
        token.forcedRecovery(alice, aliceSecondary);

        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(aliceSecondary), AMOUNT);
        assertEq(token.totalSupply(), AMOUNT); // supply conserved
    }

    /// @dev Recovery evicts the lost wallet from the registry so it can never hold again.
    function test_forcedRecovery_retiresLostWallet() public {
        _mint(alice, AMOUNT);

        vm.prank(custodian);
        token.forcedRecovery(alice, aliceSecondary);

        assertFalse(registry.isVerified(alice));
    }

    /// @dev A partially frozen position stays frozen at the new address: recovery relocates a
    ///      hold, it does not launder it.
    function test_forcedRecovery_carriesPartialFreeze() public {
        _mint(alice, AMOUNT);
        vm.prank(agent);
        token.freezePartialTokens(alice, AMOUNT / 2);

        vm.prank(custodian);
        token.forcedRecovery(alice, aliceSecondary);

        assertEq(token.frozenTokens(aliceSecondary), AMOUNT / 2);
        assertEq(token.frozenTokens(alice), 0);
    }

    /// @dev A fully frozen wallet is recovered into a fully frozen wallet. The lost wallet must be
    ///      unfrozen internally first, or its own freeze would block the move.
    function test_forcedRecovery_carriesFullFreeze() public {
        _mint(alice, AMOUNT);
        vm.prank(agent);
        token.setAddressFrozen(alice, true);

        vm.prank(custodian);
        token.forcedRecovery(alice, aliceSecondary);

        assertTrue(token.isFrozen(aliceSecondary));
        assertFalse(token.isFrozen(alice));
        assertEq(token.balanceOf(aliceSecondary), AMOUNT);
    }

    function test_forcedRecovery_emitsSuccess() public {
        _mint(alice, AMOUNT);
        vm.prank(agent);
        token.freezePartialTokens(alice, AMOUNT / 2);

        vm.expectEmit(true, true, false, true, address(token));
        emit ISecurityToken.RecoverySuccess(alice, aliceSecondary, AMOUNT, AMOUNT / 2, false);

        vm.prank(custodian);
        token.forcedRecovery(alice, aliceSecondary);
    }

    function test_forcedRecovery_revertsForNonCustodian() public {
        _mint(alice, AMOUNT);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, Roles.CUSTODIAN_ROLE
            )
        );
        vm.prank(attacker);
        token.forcedRecovery(alice, aliceSecondary);
    }

    function test_forcedRecovery_revertsForUnverifiedNewWallet() public {
        _mint(alice, AMOUNT);
        address stranger = makeAddr("stranger");

        vm.expectRevert(abi.encodeWithSelector(ISecurityToken.NewWalletNotVerified.selector, stranger));
        vm.prank(custodian);
        token.forcedRecovery(alice, stranger);
    }

    function test_forcedRecovery_revertsForEmptyWallet() public {
        vm.expectRevert(abi.encodeWithSelector(ISecurityToken.NothingToRecover.selector, alice));
        vm.prank(custodian);
        token.forcedRecovery(alice, aliceSecondary);
    }

    /// @dev A compliance rule must not strand a compromised position. Recovery is the tool for
    ///      resolving an incident, so a module that would reject the move (a lockup still running,
    ///      a holder cap already met) cannot be allowed to block the custodian.
    function test_forcedRecovery_succeedsWhenComplianceRejects() public {
        _mint(alice, AMOUNT);
        module.setAllow(false);

        vm.prank(custodian);
        token.forcedRecovery(alice, aliceSecondary);

        assertEq(token.balanceOf(aliceSecondary), AMOUNT);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.totalSupply(), AMOUNT);
    }

    /// @dev The destination being frozen must not block recovery either. The freeze is preserved
    ///      by the carry-over below, so the position stays held: it just stops being stranded on a
    ///      wallet the investor no longer controls.
    function test_forcedRecovery_succeedsIntoFrozenWallet() public {
        _mint(alice, AMOUNT);
        vm.prank(agent);
        token.setAddressFrozen(aliceSecondary, true);

        vm.prank(custodian);
        token.forcedRecovery(alice, aliceSecondary);

        assertEq(token.balanceOf(aliceSecondary), AMOUNT);
        assertTrue(token.isFrozen(aliceSecondary));
    }

    /// @dev Negative: a verified wallet is not enough, it must belong to the same investor.
    ///      Without this, a custodian could move a balance to an unrelated third party.
    function test_forcedRecovery_revertsAcrossInvestors() public {
        _mint(alice, AMOUNT);

        vm.expectRevert(
            abi.encodeWithSelector(ISecurityToken.RecoveryAcrossInvestors.selector, _idOf(alice), _idOf(bob))
        );
        vm.prank(custodian);
        token.forcedRecovery(alice, bob);
    }

    /// @dev A partial freeze is additive, so tokens already sitting on the destination keep their
    ///      own frozen/unfrozen split rather than being swept into the incoming hold.
    function test_forcedRecovery_partialFreezeLeavesExistingBalanceUnfrozen() public {
        _mint(alice, AMOUNT);
        _mint(aliceSecondary, AMOUNT);
        vm.prank(agent);
        token.freezePartialTokens(alice, AMOUNT / 2);

        vm.prank(custodian);
        token.forcedRecovery(alice, aliceSecondary);

        // Only the incoming hold is frozen: the pre-existing AMOUNT stays free to move.
        assertEq(token.frozenTokens(aliceSecondary), AMOUNT / 2);
        assertEq(token.balanceOf(aliceSecondary), AMOUNT * 2);
        assertFalse(token.isFrozen(aliceSecondary));
    }

    /// @dev A full freeze is a property of the investor, not of a lot, so it covers the whole
    ///      destination wallet including tokens already there. Documented trade-off: the identity
    ///      check makes this the same investor, so a blocked subject stays blocked everywhere.
    function test_forcedRecovery_fullFreezeCoversPreExistingBalance() public {
        _mint(alice, AMOUNT);
        _mint(aliceSecondary, AMOUNT);
        vm.prank(agent);
        token.setAddressFrozen(alice, true);

        vm.prank(custodian);
        token.forcedRecovery(alice, aliceSecondary);

        assertTrue(token.isFrozen(aliceSecondary));
        assertEq(token.balanceOf(aliceSecondary), AMOUNT * 2);

        // The whole wallet is now immobile, pre-existing tokens included.
        vm.expectRevert(abi.encodeWithSelector(ISecurityToken.SenderAddressFrozen.selector, aliceSecondary));
        vm.prank(aliceSecondary);
        token.transfer(carol, 1);
    }

    function test_forcedRecovery_revertsForSameWallet() public {
        _mint(alice, AMOUNT);
        vm.expectRevert(abi.encodeWithSelector(ISecurityToken.RecoveryToSameWallet.selector, alice));
        vm.prank(custodian);
        token.forcedRecovery(alice, alice);
    }

    /*//////////////////////////////////////////////////////////////
                                  FUZZ
    //////////////////////////////////////////////////////////////*/

    /// @dev Property: a transfer of any allowed amount conserves total supply.
    function testFuzz_transferConservesSupply(uint256 amount) public {
        _mint(alice, AMOUNT);
        amount = bound(amount, 0, AMOUNT);

        vm.prank(alice);
        token.transfer(bob, amount);

        assertEq(token.balanceOf(alice) + token.balanceOf(bob), AMOUNT);
        assertEq(token.totalSupply(), AMOUNT);
    }

    /// @dev Property: recovery conserves supply and never leaves value in the lost wallet, for any
    ///      freeze configuration.
    function testFuzz_recoveryConservesSupply(uint256 partialFreeze, bool fullFreeze) public {
        _mint(alice, AMOUNT);
        partialFreeze = bound(partialFreeze, 0, AMOUNT);

        if (partialFreeze != 0) {
            vm.prank(agent);
            token.freezePartialTokens(alice, partialFreeze);
        }
        if (fullFreeze) {
            vm.prank(agent);
            token.setAddressFrozen(alice, true);
        }

        vm.prank(custodian);
        token.forcedRecovery(alice, aliceSecondary);

        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(aliceSecondary), AMOUNT);
        assertEq(token.frozenTokens(aliceSecondary), partialFreeze);
        assertEq(token.isFrozen(aliceSecondary), fullFreeze);
        assertEq(token.totalSupply(), AMOUNT);
    }

    /// @dev Property: the unfrozen balance is always what the gate lets move, never more.
    function testFuzz_cannotMoveFrozenPortion(uint256 freeze, uint256 send) public {
        _mint(alice, AMOUNT);
        freeze = bound(freeze, 0, AMOUNT);
        send = bound(send, 0, AMOUNT);

        if (freeze != 0) {
            vm.prank(agent);
            token.freezePartialTokens(alice, freeze);
        }

        uint256 free = AMOUNT - freeze;
        if (send <= free) {
            vm.prank(alice);
            token.transfer(bob, send);
            assertEq(token.balanceOf(bob), send);
        } else {
            vm.expectRevert(
                abi.encodeWithSelector(ISecurityToken.InsufficientUnfrozenBalance.selector, alice, free, send)
            );
            vm.prank(alice);
            token.transfer(bob, send);
        }
    }
}
