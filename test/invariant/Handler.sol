// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";

import {SecurityToken} from "../../src/SecurityToken.sol";
import {IdentityRegistry} from "../../src/identity/IdentityRegistry.sol";
import {MaxHoldersModule} from "../../src/compliance/modules/MaxHoldersModule.sol";
import {LockupModule} from "../../src/compliance/modules/LockupModule.sol";

/**
 * @title Handler
 * @notice Drives the security token through bounded random sequences for the invariant suite.
 * @dev Three decisions shape this handler, and each is load-bearing.
 *
 *      **A fixed wallet pool.** Actors are drawn from a small fixed set rather than from fuzzed
 *      addresses. With free addresses almost every transfer would find an empty sender and revert,
 *      so the fuzzer would spend its budget rediscovering that strangers hold nothing instead of
 *      exploring the interactions between freeze, lockup, recovery and the holder cap.
 *
 *      **Everything is bounded to reachable values.** Amounts are bound against the actual balance
 *      and recipients against the pool, so a call has a real chance of succeeding. The suite runs
 *      with `fail_on_revert = false` because many actions must legitimately revert (a locked-up
 *      transfer, a frozen sender), but that setting is also how an invariant suite silently tests
 *      nothing: if every call reverted, every invariant would hold vacuously.
 *
 *      **Hence the counters.** Each action increments a counter only when the call actually
 *      succeeded, and the suite asserts the important ones are non-zero. They are part of the
 *      deliverable, not diagnostics: without them a green run is not evidence of anything.
 *
 *      Ghost state tracks what the system does not expose. `ghostMinted`/`ghostBurned` give an
 *      independent expectation for total supply, and `ghostRecovered` records wallets evicted by
 *      recovery so the suite can assert they never hold again.
 */
contract Handler is CommonBase, StdCheats, StdUtils {
    /*//////////////////////////////////////////////////////////////
                                 SYSTEM
    //////////////////////////////////////////////////////////////*/

    SecurityToken internal immutable token;
    IdentityRegistry internal immutable registry;
    MaxHoldersModule internal immutable maxHolders;
    LockupModule internal immutable lockup;

    address internal immutable issuer;
    address internal immutable agent;
    address internal immutable custodian;

    /*//////////////////////////////////////////////////////////////
                                 ACTORS
    //////////////////////////////////////////////////////////////*/

    /// @dev The wallet pool. Held as a fixed array so the invariant contract can sum balances
    ///      across exactly the addresses that can ever hold a balance.
    address[6] public actors;

    /// @dev Investor id shared by actors 0 and 1, and by 2 and 3, so recovery has valid
    ///      destinations to find. Actors 4 and 5 are their own investors, so a recovery between
    ///      them and anyone else must be rejected.
    mapping(address actor => bytes32 id) public investorIdOf;

    /*//////////////////////////////////////////////////////////////
                               GHOST STATE
    //////////////////////////////////////////////////////////////*/

    uint256 public ghostMinted;
    uint256 public ghostBurned;

    /// @dev Wallets evicted by a recovery, in insertion order.
    address[] public ghostRecovered;
    mapping(address wallet => bool evicted) public ghostIsRecovered;

    /// @dev Balance of an evicted wallet at the instant recovery completed. Recovery must always
    ///      leave it at zero; a later re-onboarding may legitimately give it a balance again.
    mapping(address wallet => uint256 balance) public ghostBalanceAtEviction;

    /*//////////////////////////////////////////////////////////////
                                COUNTERS
    //////////////////////////////////////////////////////////////*/

    uint256 public callsMint;
    uint256 public callsBurn;
    uint256 public callsTransfer;
    uint256 public callsFreezeAddress;
    uint256 public callsUnfreezeAddress;
    uint256 public callsFreezePartial;
    uint256 public callsUnfreezePartial;
    uint256 public callsPause;
    uint256 public callsUnpause;
    uint256 public callsRecover;
    uint256 public callsRemoveIdentity;
    uint256 public callsRegisterIdentity;
    uint256 public callsWarp;

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(
        SecurityToken token_,
        IdentityRegistry registry_,
        MaxHoldersModule maxHolders_,
        LockupModule lockup_,
        address issuer_,
        address agent_,
        address custodian_,
        address[6] memory actors_,
        bytes32[6] memory ids_
    ) {
        token = token_;
        registry = registry_;
        maxHolders = maxHolders_;
        lockup = lockup_;
        issuer = issuer_;
        agent = agent_;
        custodian = custodian_;
        actors = actors_;

        for (uint256 i; i < actors_.length; ++i) {
            investorIdOf[actors_[i]] = ids_[i];
        }
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _actor(uint256 seed) internal view returns (address) {
        return actors[bound(seed, 0, actors.length - 1)];
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function recoveredCount() external view returns (uint256) {
        return ghostRecovered.length;
    }

    /*//////////////////////////////////////////////////////////////
                                ACTIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev Issuance. Bounded well below the holder cap's reach so supply stays legible.
    function mint(uint256 toSeed, uint256 amount) external {
        address to = _actor(toSeed);
        amount = bound(amount, 1, 1_000_000e18);

        vm.prank(issuer);
        try token.mint(to, amount) {
            ghostMinted += amount;
            ++callsMint;
        } catch {}
    }

    /// @dev Retirement. The issuer may burn through a freeze, which is what makes the frozen
    ///      reconciliation worth asserting as an invariant.
    function burn(uint256 fromSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        uint256 balance = token.balanceOf(from);
        if (balance == 0) return;
        amount = bound(amount, 1, balance);

        vm.prank(issuer);
        try token.burn(from, amount) {
            ghostBurned += amount;
            ++callsBurn;
        } catch {}
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 balance = token.balanceOf(from);
        if (balance == 0) return;
        amount = bound(amount, 1, balance);

        vm.prank(from);
        try token.transfer(to, amount) {
            ++callsTransfer;
        } catch {}
    }

    function setAddressFrozen(uint256 whoSeed, bool freeze) external {
        address who = _actor(whoSeed);

        vm.prank(agent);
        try token.setAddressFrozen(who, freeze) {
            if (freeze) ++callsFreezeAddress;
            else ++callsUnfreezeAddress;
        } catch {}
    }

    function freezePartialTokens(uint256 whoSeed, uint256 amount) external {
        address who = _actor(whoSeed);
        uint256 balance = token.balanceOf(who);
        uint256 frozen = token.frozenTokens(who);
        if (balance <= frozen) return;
        amount = bound(amount, 1, balance - frozen);

        vm.prank(agent);
        try token.freezePartialTokens(who, amount) {
            ++callsFreezePartial;
        } catch {}
    }

    function unfreezePartialTokens(uint256 whoSeed, uint256 amount) external {
        address who = _actor(whoSeed);
        uint256 frozen = token.frozenTokens(who);
        if (frozen == 0) return;
        amount = bound(amount, 1, frozen);

        vm.prank(agent);
        try token.unfreezePartialTokens(who, amount) {
            ++callsUnfreezePartial;
        } catch {}
    }

    /**
     * @dev Pause and unpause as a single toggling action rather than two independent ones.
     *
     *      As two actions the fuzzer reaches a paused state and then, on most subsequent draws,
     *      picks something other than unpause: the run spends the rest of its depth with every
     *      balance-moving call reverting on the pause, and the invariants hold over a system that
     *      did nothing. Toggling keeps both states reachable while guaranteeing the paused stretch
     *      ends. The exemption recovery enjoys while paused is still exercised, since recovery
     *      draws land inside those stretches.
     */
    /**
     * @dev The `seed` parameter exists only to make pausing rare.
     *
     *      Forge draws each handler action with roughly equal probability, so an unconditional
     *      toggle would leave the token paused for about half of every run, and half the sequence
     *      would be spent watching balance-moving calls revert on the pause rather than exploring
     *      the interactions between them. Entering a pause on a fraction of the draws keeps the
     *      paused state (and recovery's exemption from it) reachable while leaving most of the
     *      depth for the paths that actually move balances. Leaving one is never throttled, so a
     *      paused stretch stays short.
     */
    function togglePause(uint256 seed) external {
        // The prank must sit immediately before the state-changing call: it applies to the next
        // call only, and reading `paused()` first would consume it.
        bool isPaused = token.paused();
        if (!isPaused && bound(seed, 0, 9) != 0) return;

        if (isPaused) {
            vm.prank(agent);
            try token.unpause() {
                ++callsUnpause;
            } catch {}
        } else {
            vm.prank(agent);
            try token.pause() {
                ++callsPause;
            } catch {}
        }
    }

    /**
     * @dev Recovery between two pool wallets. Most draws are rejected because the two actors do
     *      not share an investor id, which is intended: the rejection path is as much a part of
     *      the property as the success path.
     */
    function forcedRecovery(uint256 lostSeed, uint256 newSeed) external {
        address lost = _actor(lostSeed);
        address replacement = _actor(newSeed);

        vm.prank(custodian);
        try token.forcedRecovery(lost, replacement) {
            ++callsRecover;
            // Record the balance the instant the eviction completed. A wallet may legitimately be
            // re-onboarded later and hold again, so the property worth asserting is that recovery
            // left it empty at the time, not that it stays empty forever.
            ghostBalanceAtEviction[lost] = token.balanceOf(lost);
            if (!ghostIsRecovered[lost]) {
                ghostIsRecovered[lost] = true;
                ghostRecovered.push(lost);
            }
        } catch {}
    }

    /**
     * @dev Withdrawing an identity and restoring it, as one toggling action.
     *
     *      Withdrawal is the action that creates the state the "verified holders only" invariant
     *      had to be reformulated around: a wallet keeps its balance while unverified, and cannot
     *      move it. That state must be reachable, which is why the action exists at all.
     *
     *      It toggles for the same reason pause does, only more sharply. As a standalone action,
     *      withdrawal accumulates: within a few draws the whole pool is unverified, and from there
     *      every mint and every transfer reverts on the identity check for the rest of the run.
     *      Restoring on the next draw of the same actor keeps the suspended state frequent and
     *      short-lived instead of terminal.
     *
     *      The restored record always carries the actor's original investor id, so recovery
     *      destinations stay valid across a withdrawal.
     */
    function toggleIdentity(uint256 whoSeed, uint256 throttleSeed, uint16 country, bool accredited) external {
        address who = _actor(whoSeed);

        // Throttled for the same reason as the pause: withdrawal blocks the wallet on both sides
        // of a transfer, so withdrawing on every draw would starve the paths worth exploring.
        // Restoring is never throttled, so a suspension stays short. The throttle reads its own
        // parameter rather than reusing `country`, which is bound to a non-zero range just below.
        bool verified = registry.isVerified(who);
        if (verified && bound(throttleSeed, 0, 4) != 0) return;

        country = uint16(bound(country, 1, 999));

        vm.startPrank(agent);
        if (verified) {
            try registry.removeIdentity(who) {
                ++callsRemoveIdentity;
            } catch {}
        } else {
            try registry.registerIdentity(
                who, country, accredited, uint64(block.timestamp + 365 days), investorIdOf[who]
            ) {
                ++callsRegisterIdentity;
            } catch {}
        }
        vm.stopPrank();
    }

    /// @dev Time passes. Without this the lockup would block every transfer for the whole run and
    ///      the suite would explore only the rejected side of the rule.
    function warp(uint256 secondsAhead) external {
        secondsAhead = bound(secondsAhead, 1 hours, 30 days);
        vm.warp(block.timestamp + secondsAhead);
        ++callsWarp;
    }
}
