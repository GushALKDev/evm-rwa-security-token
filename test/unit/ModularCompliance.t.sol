// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {ModularCompliance} from "../../src/compliance/ModularCompliance.sol";
import {IModularCompliance} from "../../src/interfaces/IModularCompliance.sol";
import {IComplianceModule} from "../../src/interfaces/IComplianceModule.sol";
import {MockModule, WrongEngineModule} from "../helpers/MockModule.sol";

contract ModularComplianceTest is Test {
    ModularCompliance internal engine;
    MockModule internal moduleA;
    MockModule internal moduleB;

    address internal issuer = makeAddr("issuer");
    address internal tokenAddr = makeAddr("token");
    address internal stranger = makeAddr("stranger");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    uint256 internal constant AMOUNT = 1_000e18;

    function setUp() public {
        engine = new ModularCompliance(issuer);
        moduleA = new MockModule(address(engine), "ModuleA");
        moduleB = new MockModule(address(engine), "ModuleB");
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _addBoth() internal {
        vm.startPrank(issuer);
        engine.addModule(address(moduleA));
        engine.addModule(address(moduleB));
        vm.stopPrank();
    }

    function _bind() internal {
        vm.prank(issuer);
        engine.bindToken(tokenAddr);
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    function test_constructor_setsState() public view {
        assertTrue(engine.hasRole(engine.DEFAULT_ADMIN_ROLE(), issuer));
        assertEq(engine.token(), address(0));
        assertEq(engine.modules().length, 0);
    }

    function test_constructor_revertsOnZeroIssuer() public {
        vm.expectRevert(IModularCompliance.ZeroAddress.selector);
        new ModularCompliance(address(0));
    }

    /*//////////////////////////////////////////////////////////////
                              ADD MODULE
    //////////////////////////////////////////////////////////////*/

    function test_addModule_registers() public {
        vm.expectEmit(true, false, false, false, address(engine));
        emit IModularCompliance.ModuleAdded(address(moduleA));

        vm.prank(issuer);
        engine.addModule(address(moduleA));

        assertTrue(engine.isModuleRegistered(address(moduleA)));
        address[] memory list = engine.modules();
        assertEq(list.length, 1);
        assertEq(list[0], address(moduleA));
    }

    function test_addModule_revertsForNonAdmin() public {
        bytes32 adminRole = engine.DEFAULT_ADMIN_ROLE();
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, adminRole)
        );
        engine.addModule(address(moduleA));
    }

    function test_addModule_revertsOnZeroAddress() public {
        vm.prank(issuer);
        vm.expectRevert(IModularCompliance.ZeroAddress.selector);
        engine.addModule(address(0));
    }

    function test_addModule_revertsOnDuplicate() public {
        vm.startPrank(issuer);
        engine.addModule(address(moduleA));
        vm.expectRevert(abi.encodeWithSelector(IModularCompliance.ModuleAlreadyAdded.selector, address(moduleA)));
        engine.addModule(address(moduleA));
        vm.stopPrank();
    }

    function test_addModule_revertsForModuleBoundToDifferentEngine() public {
        WrongEngineModule wrong = new WrongEngineModule(address(0xBEEF));
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(IModularCompliance.ModuleNotBound.selector, address(wrong)));
        engine.addModule(address(wrong));
    }

    /*//////////////////////////////////////////////////////////////
                             REMOVE MODULE
    //////////////////////////////////////////////////////////////*/

    function test_removeModule_deregisters() public {
        _addBoth();

        vm.expectEmit(true, false, false, false, address(engine));
        emit IModularCompliance.ModuleRemoved(address(moduleA));

        vm.prank(issuer);
        engine.removeModule(address(moduleA));

        assertFalse(engine.isModuleRegistered(address(moduleA)));
        assertTrue(engine.isModuleRegistered(address(moduleB)));
        assertEq(engine.modules().length, 1);
    }

    function test_removeModule_revertsForNonAdmin() public {
        _addBoth();
        bytes32 adminRole = engine.DEFAULT_ADMIN_ROLE();
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, adminRole)
        );
        engine.removeModule(address(moduleA));
    }

    function test_removeModule_revertsWhenNotRegistered() public {
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(IModularCompliance.ModuleNotFound.selector, address(moduleA)));
        engine.removeModule(address(moduleA));
    }

    /*//////////////////////////////////////////////////////////////
                              BIND TOKEN
    //////////////////////////////////////////////////////////////*/

    function test_bindToken_binds() public {
        vm.expectEmit(true, false, false, false, address(engine));
        emit IModularCompliance.TokenBound(tokenAddr);

        vm.prank(issuer);
        engine.bindToken(tokenAddr);

        assertEq(engine.token(), tokenAddr);
    }

    function test_bindToken_revertsForNonAdmin() public {
        bytes32 adminRole = engine.DEFAULT_ADMIN_ROLE();
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, adminRole)
        );
        engine.bindToken(tokenAddr);
    }

    function test_bindToken_revertsOnZeroAddress() public {
        vm.prank(issuer);
        vm.expectRevert(IModularCompliance.ZeroAddress.selector);
        engine.bindToken(address(0));
    }

    function test_bindToken_revertsWhenAlreadyBound() public {
        _bind();
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(IModularCompliance.TokenAlreadyBound.selector, tokenAddr));
        engine.bindToken(makeAddr("otherToken"));
    }

    /*//////////////////////////////////////////////////////////////
                              CAN TRANSFER
    //////////////////////////////////////////////////////////////*/

    function test_canTransfer_trueWithNoModules() public view {
        assertTrue(engine.canTransfer(alice, bob, AMOUNT));
    }

    function test_canTransfer_trueWhenAllModulesAllow() public {
        _addBoth();
        assertTrue(engine.canTransfer(alice, bob, AMOUNT));
    }

    function test_canTransfer_falseWhenAnyModuleRejects() public {
        _addBoth();
        moduleB.setAllow(false);
        assertFalse(engine.canTransfer(alice, bob, AMOUNT));
    }

    function test_canTransfer_falseWhenFirstModuleRejects() public {
        _addBoth();
        moduleA.setAllow(false);
        assertFalse(engine.canTransfer(alice, bob, AMOUNT));
    }

    /*//////////////////////////////////////////////////////////////
                             LIFECYCLE HOOKS
    //////////////////////////////////////////////////////////////*/

    function test_transferred_fansOutToEveryModule() public {
        _addBoth();
        _bind();

        vm.prank(tokenAddr);
        engine.transferred(alice, bob, AMOUNT);

        assertEq(moduleA.transferredCount(), 1);
        assertEq(moduleB.transferredCount(), 1);
        assertEq(moduleA.lastFrom(), alice);
        assertEq(moduleA.lastTo(), bob);
        assertEq(moduleA.lastAmount(), AMOUNT);
    }

    function test_created_fansOutToEveryModule() public {
        _addBoth();
        _bind();

        vm.prank(tokenAddr);
        engine.created(bob, AMOUNT);

        assertEq(moduleA.createdCount(), 1);
        assertEq(moduleB.createdCount(), 1);
        assertEq(moduleA.lastTo(), bob);
        assertEq(moduleA.lastAmount(), AMOUNT);
    }

    function test_destroyed_fansOutToEveryModule() public {
        _addBoth();
        _bind();

        vm.prank(tokenAddr);
        engine.destroyed(alice, AMOUNT);

        assertEq(moduleA.destroyedCount(), 1);
        assertEq(moduleB.destroyedCount(), 1);
        assertEq(moduleA.lastFrom(), alice);
        assertEq(moduleA.lastAmount(), AMOUNT);
    }

    function test_hooks_noopWithNoModules() public {
        _bind();
        vm.startPrank(tokenAddr);
        engine.transferred(alice, bob, AMOUNT);
        engine.created(bob, AMOUNT);
        engine.destroyed(alice, AMOUNT);
        vm.stopPrank();
    }

    function test_transferred_revertsForNonToken() public {
        _addBoth();
        _bind();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IModularCompliance.OnlyToken.selector, stranger, tokenAddr));
        engine.transferred(alice, bob, AMOUNT);
    }

    function test_created_revertsForNonToken() public {
        _bind();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IModularCompliance.OnlyToken.selector, stranger, tokenAddr));
        engine.created(bob, AMOUNT);
    }

    function test_destroyed_revertsForNonToken() public {
        _bind();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IModularCompliance.OnlyToken.selector, stranger, tokenAddr));
        engine.destroyed(alice, AMOUNT);
    }

    function test_hooks_revertBeforeBind() public {
        _addBoth();
        // No token bound: _token is zero, so even the real token address is not yet the caller.
        vm.prank(tokenAddr);
        vm.expectRevert(abi.encodeWithSelector(IModularCompliance.OnlyToken.selector, tokenAddr, address(0)));
        engine.transferred(alice, bob, AMOUNT);
    }

    /*//////////////////////////////////////////////////////////////
                                  FUZZ
    //////////////////////////////////////////////////////////////*/

    function testFuzz_canTransfer_requiresEveryModule(bool a, bool b) public {
        _addBoth();
        moduleA.setAllow(a);
        moduleB.setAllow(b);
        assertEq(engine.canTransfer(alice, bob, AMOUNT), a && b);
    }

    function testFuzz_transferred_fansOut(address from, address to, uint256 amount) public {
        _addBoth();
        _bind();
        vm.prank(tokenAddr);
        engine.transferred(from, to, amount);
        assertEq(moduleA.transferredCount(), 1);
        assertEq(moduleB.transferredCount(), 1);
        assertEq(moduleB.lastAmount(), amount);
    }
}
