// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {CountryRestrictionModule} from "../../src/compliance/modules/CountryRestrictionModule.sol";
import {IdentityRegistry} from "../../src/identity/IdentityRegistry.sol";
import {IComplianceModule} from "../../src/interfaces/IComplianceModule.sol";
import {Roles} from "../../src/Roles.sol";

contract CountryRestrictionModuleTest is Test {
    CountryRestrictionModule internal module;
    IdentityRegistry internal registry;

    address internal engine = makeAddr("compliance");
    address internal issuer = makeAddr("issuer");
    address internal agent = makeAddr("agent");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    uint16 internal constant ES = 724; // Spain
    uint16 internal constant FR = 250; // France
    uint16 internal constant KP = 408; // North Korea, the archetypal restricted jurisdiction

    uint64 internal expiry;
    uint256 internal constant AMOUNT = 1_000e18;

    function setUp() public {
        vm.warp(1_700_000_000);
        expiry = uint64(block.timestamp + 365 days);

        registry = new IdentityRegistry(issuer, agent);
        module = new CountryRestrictionModule(engine, address(registry), issuer, agent);

        vm.startPrank(agent);
        registry.registerIdentity(alice, ES, true, expiry);
        registry.registerIdentity(bob, FR, true, expiry);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    function test_constructor_setsState() public view {
        assertEq(module.compliance(), engine);
        assertEq(module.identityRegistry(), address(registry));
        assertEq(module.name(), "CountryRestrictionModule");
        assertTrue(module.hasRole(module.DEFAULT_ADMIN_ROLE(), issuer));
        assertTrue(module.hasRole(Roles.AGENT_ROLE, agent));
    }

    function test_constructor_revertsOnZeroRegistry() public {
        vm.expectRevert(CountryRestrictionModule.ZeroAddress.selector);
        new CountryRestrictionModule(engine, address(0), issuer, agent);
    }

    function test_constructor_revertsOnZeroCompliance() public {
        vm.expectPartialRevert(IComplianceModule.OnlyCompliance.selector);
        new CountryRestrictionModule(address(0), address(registry), issuer, agent);
    }

    /*//////////////////////////////////////////////////////////////
                              ENFORCEMENT
    //////////////////////////////////////////////////////////////*/

    function test_moduleCheck_allowsUnrestrictedCountry() public view {
        assertTrue(module.moduleCheck(alice, bob, AMOUNT));
    }

    function test_moduleCheck_blocksRestrictedRecipient() public {
        vm.prank(agent);
        module.setCountryRestricted(FR, true);

        assertFalse(module.moduleCheck(alice, bob, AMOUNT));
    }

    /// @dev The rule looks at the recipient's jurisdiction, not the sender's: a restricted sender
    ///      may still dispose of their position, which is what an exit from a sanctioned
    ///      jurisdiction requires.
    function test_moduleCheck_ignoresSenderCountry() public {
        vm.prank(agent);
        module.setCountryRestricted(ES, true);

        assertTrue(module.moduleCheck(alice, bob, AMOUNT), "restricted sender may still send");
        assertFalse(module.moduleCheck(bob, alice, AMOUNT), "restricted recipient may not receive");
    }

    /// @dev A burn has no recipient to place in a jurisdiction.
    function test_moduleCheck_allowsBurn() public {
        vm.prank(agent);
        module.setCountryRestricted(ES, true);

        assertTrue(module.moduleCheck(alice, address(0), AMOUNT));
    }

    /// @dev An unregistered recipient reads as country 0, which is not a real ISO code and is
    ///      unrestricted by default. The identity check in the token is what stops this transfer,
    ///      not this module: each rule answers exactly one question.
    function test_moduleCheck_unregisteredRecipientReadsAsCountryZero() public {
        address ghost = makeAddr("ghost");
        assertEq(registry.country(ghost), 0);
        assertTrue(module.moduleCheck(alice, ghost, AMOUNT));

        vm.prank(agent);
        module.setCountryRestricted(0, true);
        assertFalse(module.moduleCheck(alice, ghost, AMOUNT));
    }

    function test_moduleCheck_unrestrictingRestoresTransfers() public {
        vm.startPrank(agent);
        module.setCountryRestricted(FR, true);
        assertFalse(module.moduleCheck(alice, bob, AMOUNT));

        module.setCountryRestricted(FR, false);
        assertTrue(module.moduleCheck(alice, bob, AMOUNT));
        vm.stopPrank();
    }

    /// @dev Restricting a jurisdiction does not claw back existing holders: it stops new
    ///      inflows. Seizing an existing position is the freeze and recovery machinery's job.
    function test_restrictionDoesNotAffectExistingHolders() public {
        vm.prank(agent);
        module.setCountryRestricted(FR, true);

        assertTrue(module.moduleCheck(bob, alice, AMOUNT), "bob can still exit his position");
    }

    /*//////////////////////////////////////////////////////////////
                              RULE ADMIN
    //////////////////////////////////////////////////////////////*/

    function test_setCountryRestricted_updatesAndEmits() public {
        vm.expectEmit(true, false, false, true, address(module));
        emit CountryRestrictionModule.CountryRestrictionUpdated(KP, true);

        vm.prank(agent);
        module.setCountryRestricted(KP, true);

        assertTrue(module.isRestricted(KP));
    }

    /// @dev Negative: the blocklist is agent-gated.
    function test_setCountryRestricted_revertsForNonAgent() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, Roles.AGENT_ROLE)
        );
        vm.prank(alice);
        module.setCountryRestricted(KP, true);
    }

    /// @dev Negative: the issuer is admin but not agent, so the sanctions list is not theirs.
    function test_setCountryRestricted_revertsForIssuer() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, issuer, Roles.AGENT_ROLE)
        );
        vm.prank(issuer);
        module.setCountryRestricted(KP, true);
    }

    /*//////////////////////////////////////////////////////////////
                              HOOK ACCESS
    //////////////////////////////////////////////////////////////*/

    /// @dev The hooks are no-ops here, but still gated: an ungated hook on a stateless module
    ///      today becomes an ungated hook on a stateful one after one refactor.
    function test_hooks_revertForNonCompliance() public {
        vm.startPrank(alice);

        vm.expectRevert(abi.encodeWithSelector(IComplianceModule.OnlyCompliance.selector, alice, engine));
        module.moduleTransferred(alice, bob, AMOUNT);

        vm.expectRevert(abi.encodeWithSelector(IComplianceModule.OnlyCompliance.selector, alice, engine));
        module.moduleCreated(alice, AMOUNT);

        vm.expectRevert(abi.encodeWithSelector(IComplianceModule.OnlyCompliance.selector, alice, engine));
        module.moduleDestroyed(alice, AMOUNT);

        vm.stopPrank();
    }

    function test_hooks_acceptComplianceAndDoNothing() public {
        vm.startPrank(engine);
        module.moduleTransferred(alice, bob, AMOUNT);
        module.moduleCreated(alice, AMOUNT);
        module.moduleDestroyed(alice, AMOUNT);
        vm.stopPrank();

        assertTrue(module.moduleCheck(alice, bob, AMOUNT));
    }

    /*//////////////////////////////////////////////////////////////
                                  FUZZ
    //////////////////////////////////////////////////////////////*/

    /// @dev Property: the check mirrors the blocklist for the recipient's country, always.
    function testFuzz_moduleCheck_mirrorsBlocklist(uint16 country, bool restricted) public {
        vm.assume(country != 0);

        address who = makeAddr("fuzzInvestor");
        vm.prank(agent);
        registry.registerIdentity(who, country, true, expiry);

        vm.prank(agent);
        module.setCountryRestricted(country, restricted);

        assertEq(module.moduleCheck(alice, who, AMOUNT), !restricted);
    }

    /// @dev Property: restricting one country never affects another.
    function testFuzz_restrictionsAreIndependent(uint16 blocked, uint16 other) public {
        vm.assume(blocked != other);

        address who = makeAddr("otherInvestor");
        vm.prank(agent);
        registry.registerIdentity(who, other, true, expiry);

        vm.prank(agent);
        module.setCountryRestricted(blocked, true);

        assertTrue(module.moduleCheck(alice, who, AMOUNT));
    }
}
