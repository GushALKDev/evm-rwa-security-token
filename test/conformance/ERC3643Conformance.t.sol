// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {Deploy} from "../../script/Deploy.s.sol";
import {ISecurityToken} from "../../src/interfaces/ISecurityToken.sol";
import {IModularCompliance} from "../../src/interfaces/IModularCompliance.sol";
import {IComplianceModule} from "../../src/interfaces/IComplianceModule.sol";
import {CountryRestrictionModule} from "../../src/compliance/modules/CountryRestrictionModule.sol";

/**
 * @title ERC3643ConformanceTest
 * @notice Checks the functions the README lists as implemented as in ERC-3643 against the EIP
 *         text, and compares every event this system emits for those operations with the event
 *         the EIP and the T-REX interfaces define.
 * @dev Event comparison is by topic0, the keccak256 of the canonical signature. Where the two
 *      differ, the test asserts this system's signature and names the standard one, so a change
 *      in either direction shows up here. Differences, all documented in the README:
 *
 *      - `AddressFrozen(address,bool)` here; the standard has `AddressFrozen(address,bool,address)`,
 *        the third argument being the agent that acted.
 *      - `RecoverySuccess(address,address,uint256,uint256,bool)` here (amount and the carried
 *        freeze state); the standard has `RecoverySuccess(address,address,address)` with the
 *        investor's ONCHAINID.
 *      - `IdentityRegistered(address,uint16,bool,uint64,bytes32,bool)` and
 *        `IdentityRemoved(address)` here; the standard's carry the investor's `IIdentity`
 *        contract, which does not exist in this design.
 *      - `IdentityRegistrySet` / `ComplianceSet` here, emitted once in the constructor; the
 *        standard has `IdentityRegistryAdded` / `ComplianceAdded`, emitted by its setters.
 *      - `TokenBound(address)` has the same signature, but the address is indexed here and not
 *        in the standard, so it travels in a topic instead of the data.
 *
 *      Matching: `Paused(address)` and `Unpaused(address)` (from OpenZeppelin), `TokensFrozen`,
 *      `TokensUnfrozen`, `ModuleAdded`, `ModuleRemoved`, `ComplianceBound`, `ComplianceUnbound`.
 */
contract ERC3643ConformanceTest is Test, Deploy {
    Deployment internal d;

    address internal issuer = address(this);
    address internal agent = makeAddr("agent");
    address internal custodian = makeAddr("custodian");
    address internal alice = makeAddr("alice");
    address internal aliceNew = makeAddr("aliceNew");
    address internal bob = makeAddr("bob");

    uint256 internal constant AMOUNT = 1_000e18;

    function setUp() public {
        d = _deploy(issuer, agent, custodian);
        bytes32 aliceId = keccak256("investor-alice");
        vm.startPrank(agent);
        d.identityRegistry.registerIdentity(alice, 724, true, uint64(block.timestamp + 3650 days), aliceId);
        d.identityRegistry.registerIdentity(aliceNew, 724, true, uint64(block.timestamp + 3650 days), aliceId);
        d.identityRegistry.registerIdentity(bob, 724, true, uint64(block.timestamp + 3650 days));
        vm.stopPrank();
        d.token.mint(alice, AMOUNT);
        vm.warp(block.timestamp + LOCKUP_PERIOD + 1);
    }

    /// @dev The topic0 of the first log `emitter` emitted in `logs`, or zero.
    function _firstTopic(Vm.Log[] memory logs, address emitter) internal pure returns (bytes32) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == emitter) return logs[i].topics[0];
        }
        return bytes32(0);
    }

    /// @dev Every topic0 `emitter` emitted, in order.
    function _topics(Vm.Log[] memory logs, address emitter) internal pure returns (bytes32[] memory out) {
        uint256 n;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == emitter) ++n;
        }
        out = new bytes32[](n);
        n = 0;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == emitter) out[n++] = logs[i].topics[0];
        }
    }

    /*//////////////////////////////////////////////////////////////
                                 PAUSE
    //////////////////////////////////////////////////////////////*/

    /// @dev EIP: "The token MUST NOT be paused" for a transfer. `pause` and `unpause` are agent
    ///      actions and emit `Paused(address)` / `Unpaused(address)`, as in the standard.
    function test_pause_blocksTransfersAndMatchesEvents() public {
        vm.recordLogs();
        vm.prank(agent);
        d.token.pause();
        assertEq(_firstTopic(vm.getRecordedLogs(), address(d.token)), keccak256("Paused(address)"));
        assertTrue(d.token.paused());

        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(alice);
        d.token.transfer(bob, 1);

        vm.recordLogs();
        vm.prank(agent);
        d.token.unpause();
        assertEq(_firstTopic(vm.getRecordedLogs(), address(d.token)), keccak256("Unpaused(address)"));
        assertFalse(d.token.paused());
    }

    /*//////////////////////////////////////////////////////////////
                                 FREEZE
    //////////////////////////////////////////////////////////////*/

    /// @dev EIP: neither the sender's nor the receiver's wallet may be frozen. Semantics match;
    ///      the event differs (see the contract NatSpec).
    function test_setAddressFrozen_semanticsMatch_eventDiffers() public {
        vm.recordLogs();
        vm.prank(agent);
        d.token.setAddressFrozen(bob, true);
        bytes32 topic = _firstTopic(vm.getRecordedLogs(), address(d.token));
        assertEq(topic, keccak256("AddressFrozen(address,bool)"));
        assertTrue(topic != keccak256("AddressFrozen(address,bool,address)"), "now matches the standard");
        assertTrue(d.token.isFrozen(bob));

        vm.expectRevert(abi.encodeWithSelector(ISecurityToken.RecipientAddressFrozen.selector, bob));
        vm.prank(alice);
        d.token.transfer(bob, 1);

        vm.prank(agent);
        d.token.setAddressFrozen(alice, true);
        vm.prank(agent);
        d.token.setAddressFrozen(bob, false);
        vm.expectRevert(abi.encodeWithSelector(ISecurityToken.SenderAddressFrozen.selector, alice));
        vm.prank(alice);
        d.token.transfer(bob, 1);
    }

    /// @dev EIP: the sender must hold enough free balance (balance minus frozen tokens). The
    ///      partial freeze events match the standard; the getter is named `frozenTokens` here
    ///      where the standard has `getFrozenTokens`.
    function test_partialFreeze_semanticsAndEventsMatch() public {
        vm.recordLogs();
        vm.prank(agent);
        d.token.freezePartialTokens(alice, 900e18);
        assertEq(_firstTopic(vm.getRecordedLogs(), address(d.token)), keccak256("TokensFrozen(address,uint256)"));
        assertEq(d.token.frozenTokens(alice), 900e18);

        vm.expectRevert(
            abi.encodeWithSelector(ISecurityToken.InsufficientUnfrozenBalance.selector, alice, 100e18, 100e18 + 1)
        );
        vm.prank(alice);
        d.token.transfer(bob, 100e18 + 1);

        vm.recordLogs();
        vm.prank(agent);
        d.token.unfreezePartialTokens(alice, 900e18);
        assertEq(_firstTopic(vm.getRecordedLogs(), address(d.token)), keccak256("TokensUnfrozen(address,uint256)"));
    }

    /*//////////////////////////////////////////////////////////////
                               RECOVERY
    //////////////////////////////////////////////////////////////*/

    /// @dev `forcedRecovery` stands in for `recoveryAddress` and is listed as implemented
    ///      differently; only its event is compared here.
    function test_recoveryEvent_differs() public {
        vm.recordLogs();
        vm.prank(custodian);
        d.token.forcedRecovery(alice, aliceNew);
        bytes32[] memory topics = _topics(vm.getRecordedLogs(), address(d.token));
        bytes32 last = topics[topics.length - 1];
        assertEq(last, keccak256("RecoverySuccess(address,address,uint256,uint256,bool)"));
        assertTrue(last != keccak256("RecoverySuccess(address,address,address)"), "now matches the standard");
    }

    /*//////////////////////////////////////////////////////////////
                           IDENTITY REGISTRY
    //////////////////////////////////////////////////////////////*/

    /// @dev Registration and removal are listed as implemented differently; their events differ
    ///      from the standard because there is no `IIdentity` contract to name.
    function test_identityEvents_differ() public {
        address carol = makeAddr("carol");
        vm.recordLogs();
        vm.prank(agent);
        d.identityRegistry.registerIdentity(carol, 724, true, uint64(block.timestamp + 365 days));
        bytes32 registered = _firstTopic(vm.getRecordedLogs(), address(d.identityRegistry));
        assertEq(registered, keccak256("IdentityRegistered(address,uint16,bool,uint64,bytes32,bool)"));
        assertTrue(registered != keccak256("IdentityRegistered(address,address)"));

        vm.recordLogs();
        vm.prank(agent);
        d.identityRegistry.removeIdentity(carol);
        bytes32 removed = _firstTopic(vm.getRecordedLogs(), address(d.identityRegistry));
        assertEq(removed, keccak256("IdentityRemoved(address)"));
        assertTrue(removed != keccak256("IdentityRemoved(address,address)"));
    }

    /// @dev EIP `isVerified` returns the eligibility status used on every transfer. Here it
    ///      reads a stored flag and the KYC expiry rather than claims, and turns false at expiry.
    function test_isVerified_expires() public {
        address carol = makeAddr("carol");
        vm.prank(agent);
        d.identityRegistry.registerIdentity(carol, 724, true, uint64(block.timestamp + 1 days));
        assertTrue(d.identityRegistry.isVerified(carol));
        vm.warp(block.timestamp + 1 days);
        assertFalse(d.identityRegistry.isVerified(carol));
    }

    /*//////////////////////////////////////////////////////////////
                         COMPLIANCE AND MODULES
    //////////////////////////////////////////////////////////////*/

    /// @dev `addModule` / `removeModule` emit `ModuleAdded` / `ModuleRemoved(address indexed)` and
    ///      the module's `ComplianceBound` / `ComplianceUnbound(address indexed)`, as in T-REX.
    function test_moduleEvents_match() public {
        CountryRestrictionModule extra =
            new CountryRestrictionModule(address(d.compliance), address(d.identityRegistry), issuer, agent);

        vm.recordLogs();
        d.compliance.addModule(address(extra));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_firstTopic(logs, address(d.compliance)), keccak256("ModuleAdded(address)"));
        assertEq(_firstTopic(logs, address(extra)), keccak256("ComplianceBound(address)"));
        assertTrue(extra.isComplianceBound(address(d.compliance)));

        vm.recordLogs();
        d.compliance.removeModule(address(extra));
        logs = vm.getRecordedLogs();
        assertEq(_firstTopic(logs, address(d.compliance)), keccak256("ModuleRemoved(address)"));
        assertEq(_firstTopic(logs, address(extra)), keccak256("ComplianceUnbound(address)"));
    }

    /// @dev EIP: the compliance's `canTransfer` answers for the global rules only (not identity).
    ///      `transferred` / `created` / `destroyed` are callable by the bound token only.
    function test_compliance_canTransferAndHookAccess() public {
        vm.prank(agent);
        d.countryRestriction.setCountryRestricted(724, true);
        assertFalse(d.compliance.canTransfer(alice, bob, 1));
        vm.prank(agent);
        d.countryRestriction.setCountryRestricted(724, false);
        assertTrue(d.compliance.canTransfer(alice, bob, 1));

        vm.expectRevert(abi.encodeWithSelector(IModularCompliance.OnlyToken.selector, alice, address(d.token)));
        vm.prank(alice);
        d.compliance.transferred(alice, bob, 1);
    }

    /// @dev `TokenBound(address)` has the standard's signature; the address is indexed here.
    function test_tokenBoundEvent_sameSignatureIndexedHere() public {
        assertEq(IModularCompliance.TokenBound.selector, keccak256("TokenBound(address)"));
    }

    /// @dev T-REX `IModule`: `bindCompliance` / `unbindCompliance` are callable only by the
    ///      compliance, and `isPlugAndPlay` / `canComplianceBind` report the attach rules.
    function test_moduleAttachmentApi() public {
        vm.expectRevert(abi.encodeWithSelector(IComplianceModule.OnlyCompliance.selector, alice, address(d.compliance)));
        vm.prank(alice);
        d.lockup.bindCompliance(address(d.compliance));

        assertFalse(d.lockup.isPlugAndPlay());
        assertTrue(d.countryRestriction.isPlugAndPlay());
        assertFalse(d.lockup.canComplianceBind(address(d.compliance)), "attached and with supply");
        assertTrue(d.countryRestriction.canComplianceBind(address(d.compliance)));
    }
}
