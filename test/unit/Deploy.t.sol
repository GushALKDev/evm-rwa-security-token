// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {Deploy} from "../../script/Deploy.s.sol";
import {SecurityToken} from "../../src/SecurityToken.sol";
import {ISecurityToken} from "../../src/interfaces/ISecurityToken.sol";
import {IModularCompliance} from "../../src/interfaces/IModularCompliance.sol";
import {Roles} from "../../src/Roles.sol";

/**
 * @title DeployTest
 * @notice Exercises the deployment script as a unit.
 * @dev The script's own `_verify` already asserts every wiring step, so re-asserting the same
 *      equalities here would only test the assertions. What these tests add is the behaviour those
 *      assertions are a proxy for: that the wired system actually gates a transfer, that recovery
 *      can evict a wallet, and that the anchor detects a drifted document.
 *
 *      `_deploy` is called directly rather than through `run`, because `run` opens a broadcast
 *      context. The test contract is therefore the executing account, so it holds the admin roles
 *      the wiring calls need.
 */
contract DeployTest is Test, Deploy {
    Deployment internal d;

    address internal issuer = address(this);
    address internal agent = makeAddr("agent");
    address internal custodian = makeAddr("custodian");

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    /// @dev ISO 3166-1 numeric for Spain, matching the code used across the other suites.
    uint16 internal constant ES = 724;

    /// @dev KYC validity used by the helpers. Longer than LOCKUP_PERIOD on purpose: a test that
    ///      warps past the lockup must still find a current attestation, or it would assert the
    ///      wrong revert.
    uint64 internal constant KYC_WINDOW = 4 * 365 days;

    function setUp() public {
        // The deployer must hold admin for the wiring calls, so the test contract is the issuer.
        d = _deploy(issuer, agent, custodian);
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Registers a verified investor. The KYC window deliberately outlives the lockup period,
    ///      so a test that warps past the lockup does not trip an expired attestation instead.
    function _verifyInvestor(address who) internal {
        vm.prank(agent);
        d.identityRegistry.registerIdentity(who, ES, true, uint64(block.timestamp + KYC_WINDOW));
    }

    /// @dev As _verifyInvestor, but linking the wallet to an explicit investor so that two wallets
    ///      can be recognised as belonging to the same person, which recovery requires.
    function _verifyInvestorAs(address who, bytes32 id) internal {
        vm.prank(agent);
        d.identityRegistry.registerIdentity(who, ES, true, uint64(block.timestamp + KYC_WINDOW), id);
    }

    /*//////////////////////////////////////////////////////////////
                                WIRING
    //////////////////////////////////////////////////////////////*/

    /// @dev The engine only accepts lifecycle hooks from the bound token, so an unbound engine
    ///      would make every mint revert. This is the wiring step with the least visible failure.
    function test_wiring_tokenIsBoundToEngine() public view {
        assertEq(d.compliance.token(), address(d.token));
    }

    function test_wiring_allThreeModulesRegistered() public view {
        assertEq(d.compliance.modules().length, 3);
        assertTrue(d.compliance.isModuleRegistered(address(d.maxHolders)));
        assertTrue(d.compliance.isModuleRegistered(address(d.countryRestriction)));
        assertTrue(d.compliance.isModuleRegistered(address(d.lockup)));
    }

    /// @dev Forced recovery calls removeIdentity on the registry, which is AGENT-gated. Without
    ///      this grant the deployment looks fine and recovery reverts in production.
    function test_wiring_tokenHoldsAgentOnRegistry() public view {
        assertTrue(d.identityRegistry.hasRole(Roles.AGENT_ROLE, address(d.token)));
    }

    function test_wiring_operatorRolesGranted() public view {
        assertTrue(d.token.hasRole(Roles.AGENT_ROLE, agent));
        assertTrue(d.token.hasRole(Roles.CUSTODIAN_ROLE, custodian));
        assertTrue(d.token.hasRole(d.token.DEFAULT_ADMIN_ROLE(), issuer));
        assertTrue(d.identityRegistry.hasRole(Roles.AGENT_ROLE, agent));
    }

    /// @dev Separating CUSTODIAN from AGENT is the point of having two roles: a compliance desk
    ///      must not be able to seize a balance. Assert the separation is not collapsed.
    function test_wiring_agentCannotRecover() public {
        // Same investor and past the lockup, so the only thing left to reject the call is the
        // missing role. Otherwise this could pass for an unrelated reason.
        bytes32 sharedId = keccak256("investor-alice");
        _verifyInvestorAs(alice, sharedId);
        _verifyInvestorAs(bob, sharedId);
        d.token.mint(alice, 100e18);
        vm.warp(block.timestamp + LOCKUP_PERIOD + 1);

        vm.expectPartialRevert(bytes4(keccak256("AccessControlUnauthorizedAccount(address,bytes32)")));
        vm.prank(agent);
        d.token.forcedRecovery(alice, bob);
    }

    /*//////////////////////////////////////////////////////////////
                          THE SYSTEM IS LIVE
    //////////////////////////////////////////////////////////////*/

    /// @dev The end-to-end proof that the graph is closed: a mint reaches the engine, the engine
    ///      fans out to the modules, and the holder count actually moves.
    function test_live_mintReachesComplianceModules() public {
        _verifyInvestor(alice);

        d.token.mint(alice, 100e18);

        assertEq(d.token.balanceOf(alice), 100e18);
        assertEq(d.maxHolders.holderCount(), 1);
    }

    /// @dev The transfer gate is wired to the registry: an unverified recipient is rejected.
    function test_live_transferToUnverifiedReverts() public {
        _verifyInvestor(alice);
        d.token.mint(alice, 100e18);

        vm.expectRevert(abi.encodeWithSelector(ISecurityToken.RecipientNotVerified.selector, bob));
        vm.prank(alice);
        d.token.transfer(bob, 1e18);
    }

    /// @dev The lockup module is not just registered but enforcing: the deployment sets a
    ///      365-day period, so a freshly acquired position cannot move.
    function test_live_lockupBlocksEarlyTransfer() public {
        _verifyInvestor(alice);
        _verifyInvestor(bob);
        d.token.mint(alice, 100e18);

        vm.expectPartialRevert(ISecurityToken.ComplianceCheckFailed.selector);
        vm.prank(alice);
        d.token.transfer(bob, 1e18);
    }

    /// @dev And clears once the configured period has elapsed, proving the block above came from
    ///      the lockup clock rather than from some other module rejecting the transfer.
    function test_live_transferSucceedsAfterLockup() public {
        _verifyInvestor(alice);
        _verifyInvestor(bob);
        d.token.mint(alice, 100e18);

        vm.warp(block.timestamp + LOCKUP_PERIOD + 1);

        vm.prank(alice);
        d.token.transfer(bob, 40e18);

        assertEq(d.token.balanceOf(bob), 40e18);
        assertEq(d.maxHolders.holderCount(), 2);
    }

    /// @dev The country module reads the registry the script wired into it.
    function test_live_countryRestrictionBlocksRecipient() public {
        _verifyInvestor(alice);
        _verifyInvestor(bob);
        d.token.mint(alice, 100e18);
        vm.warp(block.timestamp + LOCKUP_PERIOD + 1);

        vm.prank(agent);
        d.countryRestriction.setCountryRestricted(ES, true);

        vm.expectPartialRevert(ISecurityToken.ComplianceCheckFailed.selector);
        vm.prank(alice);
        d.token.transfer(bob, 1e18);
    }

    /// @dev Recovery exercises the registry grant end to end: the token evicts the lost wallet,
    ///      which only succeeds because the script granted it AGENT.
    ///
    ///      Both wallets share an investorId, since recovery refuses to move a balance between
    ///      different investors. The warp past the lockup is required too: forcedRecovery moves
    ///      the balance with _transfer, which runs the full compliance gate, so with this
    ///      deployment's 365-day lockup a freshly minted position cannot be recovered yet.
    function test_live_forcedRecoveryEvictsLostWallet() public {
        bytes32 sharedId = keccak256("investor-alice");
        _verifyInvestorAs(alice, sharedId);
        _verifyInvestorAs(bob, sharedId);

        d.token.mint(alice, 100e18);
        vm.warp(block.timestamp + LOCKUP_PERIOD + 1);

        vm.prank(custodian);
        d.token.forcedRecovery(alice, bob);

        assertEq(d.token.balanceOf(bob), 100e18);
        assertEq(d.token.balanceOf(alice), 0);
        assertFalse(d.identityRegistry.isVerified(alice));
        assertEq(d.token.totalSupply(), 100e18);
    }

    /*//////////////////////////////////////////////////////////////
                            DOCUMENT ANCHOR
    //////////////////////////////////////////////////////////////*/

    /// @dev The anchored hash is the hash of the bytes on disk, not a constant that could drift.
    function test_anchor_matchesFileOnDisk() public view {
        (, bytes32 anchored,) = d.documentRegistry.getDocument(TERMS_NAME);

        assertEq(anchored, keccak256(bytes(vm.readFile(TERMS_PATH))));
        assertEq(anchored, d.termsHash);
    }

    function test_anchor_storesUriAndTimestamp() public view {
        (string memory uri,, uint64 lastModified) = d.documentRegistry.getDocument(TERMS_NAME);

        assertEq(uri, TERMS_URI);
        assertEq(lastModified, uint64(block.timestamp));
    }

    /// @dev The name is a readable label, not an opaque hash, so it decodes off-chain.
    function test_anchor_nameIsReadableLabel() public view {
        bytes32[] memory names = d.documentRegistry.getAllDocuments();

        assertEq(names.length, 1);
        assertEq(names[0], bytes32("TERMS"));
    }

    /// @dev The failure the anchor exists to catch: an edited document no longer matches what was
    ///      anchored. Simulated by hashing altered content rather than writing to the real file.
    function test_anchor_detectsDriftedDocument() public view {
        (, bytes32 anchored,) = d.documentRegistry.getDocument(TERMS_NAME);
        bytes32 amended = keccak256(bytes.concat(bytes(vm.readFile(TERMS_PATH)), " amended clause"));

        assertTrue(anchored != amended);
    }
}
