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
import {DividendDistributor} from "../../src/compliance/modules/DividendDistributor.sol";
import {Roles} from "../../src/Roles.sol";
import {MockCurrency} from "../helpers/MockCurrency.sol";

/**
 * @title InvariantsTest
 * @notice The properties that must hold for any sequence of calls, not just the hand-picked ones.
 * @dev The unit and scenario suites assert these at points. This suite asserts them across
 *      arbitrary interleavings of mint, burn, transfer, approve and transferFrom, both freeze
 *      pairs, pause, recovery, identity withdrawal, the country block, dividend deposits and
 *      claims, and the passage of time, which is where an ordering bug lives.
 *
 *      The system is wired by hand rather than by inheriting `Deploy`, for two reasons: the lockup
 *      is 7 days instead of the deployed 365, so sequences cross the boundary in both directions,
 *      and the holder cap is 4 instead of 499, so it is reachable within a run. The distributor is
 *      attached before the first mint. Everything else matches the real deployment.
 */
contract InvariantsTest is StdInvariant, Test {
    SecurityToken internal token;
    IdentityRegistry internal registry;
    ModularCompliance internal compliance;
    MaxHoldersModule internal maxHolders;
    CountryRestrictionModule internal countryRestriction;
    LockupModule internal lockup;
    DividendDistributor internal distributor;
    MockCurrency internal currency;
    Handler internal handler;

    address internal issuer = address(this);
    address internal agent = makeAddr("agent");
    address internal custodian = makeAddr("custodian");
    address internal outsider = makeAddr("outsider");

    uint256 internal constant MAX_HOLDERS = 4;
    uint64 internal constant LOCKUP_PERIOD = 7 days;
    uint16 internal constant ES = 724;
    uint16 internal constant FR = 250;

    address[6] internal actors;

    function setUp() public {
        compliance = new ModularCompliance(issuer);
        registry = new IdentityRegistry(issuer, agent);
        token = new SecurityToken("Real Estate Note Token", "RENT", issuer, address(registry), address(compliance));

        maxHolders = new MaxHoldersModule(address(compliance), address(token), issuer, agent, MAX_HOLDERS);
        countryRestriction = new CountryRestrictionModule(address(compliance), address(registry), issuer, agent);
        lockup = new LockupModule(address(compliance), address(token), issuer, agent, LOCKUP_PERIOD);
        currency = new MockCurrency();
        distributor = new DividendDistributor(address(compliance), address(token), address(currency), issuer);

        compliance.addModule(address(maxHolders));
        compliance.addModule(address(countryRestriction));
        compliance.addModule(address(lockup));
        compliance.addModule(address(distributor));
        compliance.bindToken(address(token));

        registry.grantRole(Roles.AGENT_ROLE, address(token));
        token.grantRole(Roles.AGENT_ROLE, agent);
        token.grantRole(Roles.CUSTODIAN_ROLE, custodian);

        currency.mint(issuer, type(uint128).max);
        currency.approve(address(distributor), type(uint256).max);

        // Three investors, two wallets each; the third investor's wallets sit in the jurisdiction
        // the country toggle can block.
        bytes32[6] memory ids;
        uint16[6] memory countries;
        for (uint256 i; i < 6; ++i) {
            actors[i] = makeAddr(string.concat("actor", vm.toString(i)));
            ids[i] = keccak256(abi.encode("investor", i / 2));
            countries[i] = i < 4 ? ES : FR;
        }

        vm.startPrank(agent);
        for (uint256 i; i < 6; ++i) {
            registry.registerIdentity(actors[i], countries[i], true, uint64(block.timestamp + 3650 days), ids[i]);
        }
        vm.stopPrank();

        handler = new Handler(
            Handler.System({
                token: token,
                registry: registry,
                countryRule: countryRestriction,
                distributor: distributor,
                lockup: lockup,
                currency: currency,
                issuer: issuer,
                agent: agent,
                custodian: custodian,
                outsider: outsider,
                blockableCountry: FR
            }),
            actors,
            ids,
            countries
        );

        targetContract(address(handler));
    }

    /*//////////////////////////////////////////////////////////////
                           SUPPLY CONSERVATION
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Balances across the whole reachable address space sum to total supply. Only the six
     *      actors can ever hold: every other address fails the identity check, the outsider
     *      included, so this is the complete sum and not a sample of it.
     */
    function invariant_balancesSumToTotalSupply() public view {
        uint256 sum = token.balanceOf(outsider);
        for (uint256 i; i < actors.length; ++i) {
            sum += token.balanceOf(actors[i]);
        }
        assertEq(sum, token.totalSupply(), "sum of balances != totalSupply");
    }

    /**
     * @dev Supply moves only through issuance and retirement. Transfers, freezes, recoveries and
     *      identity changes must all be supply-neutral.
     */
    function invariant_supplyMatchesMintsMinusBurns() public view {
        assertEq(token.totalSupply(), handler.ghostMinted() - handler.ghostBurned(), "supply != minted - burned");
    }

    /*//////////////////////////////////////////////////////////////
                            FREEZE ARITHMETIC
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev The frozen portion never exceeds the balance, or the gate's `balance - frozen` would
     *      underflow and the wallet could never transact again. Burn and recovery are the paths
     *      that have to reconcile the figure as they go.
     */
    function invariant_frozenNeverExceedsBalance() public view {
        for (uint256 i; i < actors.length; ++i) {
            assertLe(token.frozenTokens(actors[i]), token.balanceOf(actors[i]), "frozen > balance");
        }
    }

    /*//////////////////////////////////////////////////////////////
                              HOLDER COUNT
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev The module's cached count equals the number of addresses actually holding a balance.
     *      Zero-amount transfers, `transferFrom` and zero burns are in the action set, so the
     *      inference is checked on the inputs that broke it.
     */
    function invariant_holderCountMatchesReality() public view {
        uint256 live;
        for (uint256 i; i < actors.length; ++i) {
            if (token.balanceOf(actors[i]) != 0) ++live;
        }
        assertEq(maxHolders.holderCount(), live, "holderCount != live holders");
    }

    /**
     * @dev The cap is never exceeded. Forced recovery bypasses the gate, so this is not implied by
     *      it: it holds because a recovery always empties the lost wallet in the same movement.
     */
    function invariant_holderCountNeverExceedsCap() public view {
        assertLe(maxHolders.holderCount(), maxHolders.maxHolders(), "holderCount > cap");
    }

    /*//////////////////////////////////////////////////////////////
                                 LOCKUP
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev A clock runs exactly while a position exists. It starts on the zero to positive
     *      transition, is cleared on the way back to zero, ignores zero amounts, and moves with the
     *      position on a forced recovery. The module is attached before the first mint, so no
     *      position predates it.
     */
    function invariant_lockupClockMatchesPosition() public view {
        for (uint256 i; i < actors.length; ++i) {
            address a = actors[i];
            assertEq(lockup.lockStart(a) != 0, token.balanceOf(a) != 0, "clock and position disagree");
        }
    }

    /**
     * @dev Forced recovery moves a lockup clock rather than restarting it: after every successful
     *      recovery the destination holds the earlier of the two starts and the lost wallet none.
     *      Checked by the handler at the moment of each recovery, since a later state no longer
     *      shows what the starts were.
     */
    function invariant_recoveryKeepsLockupStart() public view {
        assertEq(handler.ghostRecoveryClockViolations(), 0, "recovery moved a lockup start");
    }

    /*//////////////////////////////////////////////////////////////
                                IDENTITY
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev No unverified wallet's balance grows. Withdrawing an identity suspends a position, so an
     *      unverified wallet may keep a balance, and the issuer may burn it or the custodian
     *      recover it, but a mint, a transfer or a recovery into it are all refused. The handler
     *      records each actor's balance at the moment it stops being verified (a removal, a
     *      recovery, or a KYC expiring during a warp).
     */
    function invariant_unverifiedBalanceNeverGrows() public view {
        for (uint256 i; i < actors.length; ++i) {
            address a = actors[i];
            if (!handler.ghostUnverified(a)) continue;
            assertLe(token.balanceOf(a), handler.ghostBalanceWhenUnverified(a), "unverified balance grew");
        }
    }

    /*//////////////////////////////////////////////////////////////
                               DIVIDENDS
    //////////////////////////////////////////////////////////////*/

    function _sumClaimable() internal view returns (uint256 sum) {
        for (uint256 i; i < actors.length; ++i) {
            sum += distributor.claimable(actors[i]);
        }
    }

    /// @dev The distributor always holds enough currency to pay everything it reports as owed.
    function invariant_dividendsSolvent() public view {
        assertGe(currency.balanceOf(address(distributor)), _sumClaimable(), "owes more than it holds");
    }

    /**
     * @dev Claimed plus claimable never exceeds what was deposited, and falls short of it by at
     *      most seven wei. The shortfall comes only from truncation: each account's entitlement is
     *      descaled with a floor, losing under one wei per account (six actors can hold), and the
     *      deposit remainder carried in `residue` is below one whole unit. Transfers, burns and
     *      recoveries move corrections equal and opposite, so they add no further loss.
     */
    function invariant_dividendsConserved() public view {
        uint256 paidOrOwed = handler.ghostClaimed() + _sumClaimable();
        uint256 deposited = handler.ghostDeposited();
        assertLe(paidOrOwed, deposited, "paid or owed more than deposited");
        assertGe(paidOrOwed + actors.length + 1, deposited, "lost more than the rounding allowance");
    }

    /// @dev A fully frozen or unverified holder is never paid. The entitlement is kept and counted
    ///      by the conservation invariant above; only the payout waits.
    function invariant_blockedHoldersAreNeverPaid() public view {
        assertEq(handler.ghostBlockedClaimsPaid(), 0, "a frozen or unverified holder was paid");
    }

    /*//////////////////////////////////////////////////////////////
                           REVERT CLASSIFICATION
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Every revert the handler caught was one its action may legitimately produce. The suite
     *      runs with `fail_on_revert = false` because many actions must be allowed to revert; this
     *      is what stops a panic or a wrong error from passing unseen.
     */
    function invariant_noUnexpectedReverts() public view {
        assertEq(handler.unexpectedReverts(), 0, handler.lastUnexpectedAction());
    }

    /*//////////////////////////////////////////////////////////////
                             CALL COVERAGE
    //////////////////////////////////////////////////////////////*/

    /// @dev Prints what the last run exercised, under `-vv`: per action, the calls that reached
    ///      the target, the successes, and the expected reverts by selector. A readout, not an
    ///      assertion. Virtual so a diagnostic harness can aggregate across runs.
    function afterInvariant() public virtual {
        _logCallSummary();
    }

    function _logCallSummary() internal view {
        uint256 n = handler.actionCount();
        for (uint256 i; i < n; ++i) {
            string memory action = handler.actionName(i);
            console.log(action, handler.attemptsOf(action), handler.successesOf(action));
            bytes4[] memory seen = handler.seenSelectors(action);
            for (uint256 j; j < seen.length; ++j) {
                console.logBytes4(seen[j]);
                console.log("   reverts", handler.revertsOf(action, seen[j]));
            }
        }
        console.log("unexpected reverts", handler.unexpectedReverts());
        if (handler.unexpectedReverts() != 0) console.logBytes(handler.lastUnexpected());
    }

    /**
     * @dev Every action is reachable and succeeds against a known-good state, including the
     *      paths the metrics once showed as missing: zero amounts, a full-balance exit, a spender
     *      that is not verified, recovery between two wallets of one investor, the country block
     *      and a dividend claim. It also shows the classification at work: a transfer refused by
     *      the lockup is counted as an expected revert, not an unexpected one.
     */
    function test_handlerExercisesEveryAction() public {
        handler.mint(0, 1, 0); // full mode: 1,000,000 tokens to actor 0
        handler.mint(2, 3, 500e18); // any mode: actor 2
        handler.transfer(3, 2, 0, 0); // zero amount from a wallet holding nothing
        handler.transfer(0, 2, 2, 0); // one wei, refused by the lockup
        assertEq(handler.revertsOf("transfer", bytes4(keccak256("ComplianceCheckFailed(address,address,uint256)"))), 1);

        handler.warp(8 days);
        handler.transfer(0, 2, 2, 0); // one wei, now past the lockup
        handler.approve(0, actors.length, 0, 0); // unlimited allowance to the outsider
        handler.transferFrom(actors.length, 0, 2, 2, 0); // the outsider spends it
        handler.transfer(2, 0, 1, 0); // actor 2 exits in full to an existing holder

        handler.freezePartialTokens(0, 2, 0);
        handler.unfreezePartialTokens(0, 1, 0);
        handler.setAddressFrozen(1, 0);
        handler.setAddressFrozen(1, 0);
        handler.togglePause(0);
        handler.togglePause(0);

        handler.deposit(900e6);
        handler.claim(0, 0);
        handler.forcedRecovery(0, 0, 1); // actor 0 to its partner, actor 1
        handler.toggleIdentity(0, 0); // actor 0 was de-registered by the recovery: restore it
        handler.toggleIdentity(0, 0); // and withdraw it again
        handler.toggleCountry(0);
        handler.toggleCountry(0);
        handler.burn(1, 2, 0);

        uint256 n = handler.actionCount();
        for (uint256 i; i < n; ++i) {
            string memory action = handler.actionName(i);
            assertGt(handler.successesOf(action), 0, action);
        }
        assertEq(handler.unexpectedReverts(), 0);
        assertTrue(handler.ghostUnverified(actors[0]), "suspension not tracked");
    }
}
