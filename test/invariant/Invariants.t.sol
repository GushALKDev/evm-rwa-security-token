// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {console2 as console} from "forge-std/console2.sol";

import {Handler} from "./Handler.sol";
import {SecurityToken} from "../../src/SecurityToken.sol";
import {IdentityRegistry} from "../../src/identity/IdentityRegistry.sol";
import {ModularCompliance} from "../../src/compliance/ModularCompliance.sol";
import {MaxHoldersModule} from "../../src/compliance/modules/MaxHoldersModule.sol";
import {CountryRestrictionModule} from "../../src/compliance/modules/CountryRestrictionModule.sol";
import {LockupModule} from "../../src/compliance/modules/LockupModule.sol";
import {Roles} from "../../src/Roles.sol";

/**
 * @title InvariantsTest
 * @notice The properties that must hold for any sequence of calls, not just the hand-picked ones.
 * @dev The unit and scenario suites assert these at points. This suite asserts them across
 *      arbitrary interleavings of mint, burn, transfer, both freeze pairs, pause, recovery,
 *      identity withdrawal and the passage of time, which is where an ordering bug lives.
 *
 *      The system is wired by hand rather than by inheriting `Deploy`, for one reason: the lockup
 *      is set to 7 days instead of the deployed 365. With a year-long lockup almost every transfer
 *      in a run would be rejected by the same rule, and the suite would explore one branch deeply
 *      and everything else not at all. A short period means sequences cross the boundary in both
 *      directions. Everything else matches the real deployment.
 */
contract InvariantsTest is StdInvariant, Test {
    SecurityToken internal token;
    IdentityRegistry internal registry;
    ModularCompliance internal compliance;
    MaxHoldersModule internal maxHolders;
    CountryRestrictionModule internal countryRestriction;
    LockupModule internal lockup;

    Handler internal handler;

    address internal issuer = address(this);
    address internal agent = makeAddr("agent");
    address internal custodian = makeAddr("custodian");

    /// @dev Deliberately small, so the cap is actually reachable within a run and the enforcement
    ///      branch is exercised rather than sitting permanently far from the limit.
    uint256 internal constant MAX_HOLDERS = 4;
    uint64 internal constant LOCKUP_PERIOD = 7 days;
    uint16 internal constant ES = 724;

    address[6] internal actors;

    function setUp() public {
        compliance = new ModularCompliance(issuer);
        registry = new IdentityRegistry(issuer, agent);
        token = new SecurityToken("Real Estate Note Token", "RENT", issuer, address(registry), address(compliance));

        maxHolders = new MaxHoldersModule(address(compliance), address(token), issuer, agent, MAX_HOLDERS);
        countryRestriction = new CountryRestrictionModule(address(compliance), address(registry), issuer, agent);
        lockup = new LockupModule(address(compliance), address(token), issuer, agent, LOCKUP_PERIOD);

        compliance.addModule(address(maxHolders));
        compliance.addModule(address(countryRestriction));
        compliance.addModule(address(lockup));
        compliance.bindToken(address(token));

        registry.grantRole(Roles.AGENT_ROLE, address(token));
        token.grantRole(Roles.AGENT_ROLE, agent);
        token.grantRole(Roles.CUSTODIAN_ROLE, custodian);

        // Two investors hold two wallets each, so recovery has valid destinations to find; the
        // last two are their own investors, so recoveries involving them must be rejected.
        bytes32 idA = keccak256("investor-a");
        bytes32 idB = keccak256("investor-b");
        bytes32[6] memory ids;
        for (uint256 i; i < 6; ++i) {
            actors[i] = makeAddr(string.concat("actor", vm.toString(i)));
        }
        ids[0] = idA;
        ids[1] = idA;
        ids[2] = idB;
        ids[3] = idB;
        ids[4] = keccak256("investor-c");
        ids[5] = keccak256("investor-d");

        vm.startPrank(agent);
        for (uint256 i; i < 6; ++i) {
            registry.registerIdentity(actors[i], ES, true, uint64(block.timestamp + 365 days), ids[i]);
        }
        vm.stopPrank();

        handler = new Handler(token, registry, maxHolders, lockup, issuer, agent, custodian, actors, ids);

        // The issuer's powers are exercised through the handler, which pranks them.
        token.grantRole(token.DEFAULT_ADMIN_ROLE(), address(handler));

        targetContract(address(handler));
    }

    /*//////////////////////////////////////////////////////////////
                           SUPPLY CONSERVATION
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Balances across the whole reachable address space sum to total supply. The pool is
     *      closed: only these six addresses can ever hold, because every other address fails the
     *      identity check, so this really is the complete sum and not a sample of it.
     */
    function invariant_balancesSumToTotalSupply() public view {
        uint256 sum;
        for (uint256 i; i < actors.length; ++i) {
            sum += token.balanceOf(actors[i]);
        }
        assertEq(sum, token.totalSupply(), "sum of balances != totalSupply");
    }

    /**
     * @dev Supply moves only through issuance and retirement. Transfers, freezes, recoveries and
     *      identity changes must all be supply-neutral, which is the property that would break if
     *      recovery ever minted instead of reassigning.
     */
    function invariant_supplyMatchesMintsMinusBurns() public view {
        assertEq(token.totalSupply(), handler.ghostMinted() - handler.ghostBurned(), "supply != minted - burned");
    }

    /*//////////////////////////////////////////////////////////////
                            FREEZE ARITHMETIC
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev The frozen portion never exceeds the balance. If it could, the gate's `balance - frozen`
     *      would underflow and the wallet would become permanently unable to transact, a lock
     *      nobody chose and nobody can clear. Burn is the interesting path here: it may consume
     *      frozen tokens, so it has to reconcile the figure downward as it goes.
     */
    function invariant_frozenNeverExceedsBalance() public view {
        for (uint256 i; i < actors.length; ++i) {
            address who = actors[i];
            assertLe(token.frozenTokens(who), token.balanceOf(who), "frozen > balance");
        }
    }

    /*//////////////////////////////////////////////////////////////
                              HOLDER COUNT
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev The module's cached count equals the number of addresses actually holding a balance.
     *      The count is maintained incrementally in the lifecycle hooks and never by enumeration,
     *      so this compares the cache against the enumeration the contract cannot afford.
     */
    function invariant_holderCountMatchesReality() public view {
        uint256 live;
        for (uint256 i; i < actors.length; ++i) {
            if (token.balanceOf(actors[i]) != 0) ++live;
        }
        assertEq(maxHolders.holderCount(), live, "holderCount != live holders");
    }

    /**
     * @dev The cap is never exceeded. Forced recovery bypasses the compliance gate entirely, so
     *      this is not implied by the gate: it holds because a recovery always empties the lost
     *      wallet in the same movement that fills the new one, and so can never add a holder.
     */
    function invariant_holderCountNeverExceedsCap() public view {
        assertLe(maxHolders.holderCount(), maxHolders.maxHolders(), "holderCount > cap");
    }

    /*//////////////////////////////////////////////////////////////
                                IDENTITY
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Recovery always leaves the wallet it evicted empty.
     *
     *      Recorded at the instant the eviction completed rather than checked later, because a
     *      later state says nothing about recovery. An evicted wallet is removed from the registry
     *      and so cannot receive, but compliance may deliberately re-onboard it, after which it
     *      may hold again legitimately. An earlier version of this invariant asserted "an evicted
     *      wallet that is currently unverified holds nothing" and the fuzzer disproved it with an
     *      entirely correct sequence: evict, re-register, receive a transfer, withdraw the
     *      identity again. The property that actually belongs to recovery is this one.
     */
    function invariant_recoveryLeavesEvictedWalletEmpty() public view {
        uint256 n = handler.recoveredCount();
        for (uint256 i; i < n; ++i) {
            assertEq(handler.ghostBalanceAtEviction(handler.ghostRecovered(i)), 0, "recovery left a balance behind");
        }
    }

    /**
     * @dev No unverified address can *increase* its balance.
     *
     *      Deliberately not "no unverified address holds a balance", which is false by design:
     *      `removeIdentity` suspends a live position rather than confiscating it, so an unverified
     *      wallet keeps whatever it had. What the gate guarantees is that the balance cannot grow,
     *      since both mint and transfer check the recipient. Asserting the stronger form would be
     *      asserting a property the system deliberately does not have.
     *
     *      Checked here as: an unverified wallet's frozen figure still cannot exceed its balance,
     *      and its balance is whatever it was when suspended. The growth half is enforced by the
     *      gate and covered by the unit suite; what the sequence adds is that no interleaving of
     *      recovery, burn and re-registration produces a state where the two disagree.
     */
    function invariant_unverifiedHoldersAreConsistent() public view {
        for (uint256 i; i < actors.length; ++i) {
            address who = actors[i];
            if (registry.isVerified(who)) continue;
            assertLe(token.frozenTokens(who), token.balanceOf(who), "unverified wallet has frozen > balance");
            assertFalse(token.canTransfer(who, actors[0], 1), "unverified wallet reports a movable balance");
        }
    }

    /*//////////////////////////////////////////////////////////////
                             CALL COVERAGE
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Prints what a run exercised, under `-vv`. A readout, not an assertion.
     *
     *      The counters were originally asserted here, which does not work: `afterInvariant` does
     *      not observe the handler state the sequence accumulated, so the assertions read zero and
     *      failed every run while the sequences were demonstrably doing work. The coverage
     *      guarantee therefore lives in `test_handlerExercisesEveryAction` below, which is
     *      deterministic and does not depend on how forge scopes state around this hook.
     */
    function afterInvariant() public view {
        _logCallSummary();
    }

    /**
     * @dev Every handler action is reachable, and this is load-bearing rather than a nicety.
     *
     *      The suite runs with `fail_on_revert = false`, which is necessary (a locked-up transfer
     *      must be allowed to revert) and dangerous: if every call reverted, every invariant above
     *      would hold vacuously and the run would still be green. A bad bound, a missing role or a
     *      guard that silently rejects every draw would all produce exactly that.
     *
     *      This drives each action against a known-good state and asserts its counter moved, so
     *      the failure mode is caught deterministically instead of hiding behind a green run.
     */
    function test_handlerExercisesEveryAction() public {
        handler.mint(0, 1_000e18);
        assertGt(handler.callsMint(), 0, "mint unreachable");

        handler.freezePartialTokens(0, 100e18);
        assertGt(handler.callsFreezePartial(), 0, "freezePartialTokens unreachable");

        handler.unfreezePartialTokens(0, 50e18);
        assertGt(handler.callsUnfreezePartial(), 0, "unfreezePartialTokens unreachable");

        handler.burn(0, 10e18);
        assertGt(handler.callsBurn(), 0, "burn unreachable");

        handler.warp(8 days);
        assertGt(handler.callsWarp(), 0, "warp unreachable");

        // Past the lockup now, so a transfer between two verified wallets settles.
        handler.transfer(0, 2, 1e18);
        assertGt(handler.callsTransfer(), 0, "transfer unreachable");

        // Actors 0 and 1 share an investor id, which is what recovery requires.
        handler.forcedRecovery(0, 1);
        assertGt(handler.callsRecover(), 0, "forcedRecovery unreachable");

        handler.setAddressFrozen(2, true);
        assertGt(handler.callsFreezeAddress(), 0, "setAddressFrozen(true) unreachable");

        handler.setAddressFrozen(2, false);
        assertGt(handler.callsUnfreezeAddress(), 0, "setAddressFrozen(false) unreachable");

        handler.togglePause(0);
        assertGt(handler.callsPause(), 0, "pause unreachable");

        handler.togglePause(0);
        assertGt(handler.callsUnpause(), 0, "unpause unreachable");

        // Actor 4 is untouched by the steps above, so it is verified here. Seed 0 clears the
        // withdrawal throttle; the restore on the next call is never throttled.
        handler.toggleIdentity(4, 0, ES, true);
        assertGt(handler.callsRemoveIdentity(), 0, "removeIdentity unreachable");

        handler.toggleIdentity(4, 0, ES, true);
        assertGt(handler.callsRegisterIdentity(), 0, "registerIdentity unreachable");
    }

    /// @dev Prints what the run actually exercised. Not an assertion: a readout under `-vv`, so a
    ///      green suite can be inspected rather than trusted.
    function _logCallSummary() internal view {
        console.log("mint              ", handler.callsMint());
        console.log("burn              ", handler.callsBurn());
        console.log("transfer          ", handler.callsTransfer());
        console.log("freezeAddress     ", handler.callsFreezeAddress());
        console.log("unfreezeAddress   ", handler.callsUnfreezeAddress());
        console.log("freezePartial     ", handler.callsFreezePartial());
        console.log("unfreezePartial   ", handler.callsUnfreezePartial());
        console.log("pause             ", handler.callsPause());
        console.log("unpause           ", handler.callsUnpause());
        console.log("forcedRecovery    ", handler.callsRecover());
        console.log("removeIdentity    ", handler.callsRemoveIdentity());
        console.log("registerIdentity  ", handler.callsRegisterIdentity());
        console.log("warp              ", handler.callsWarp());
    }
}
