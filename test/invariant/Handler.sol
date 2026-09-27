// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {SecurityToken} from "../../src/SecurityToken.sol";
import {IdentityRegistry} from "../../src/identity/IdentityRegistry.sol";
import {CountryRestrictionModule} from "../../src/compliance/modules/CountryRestrictionModule.sol";
import {DividendDistributor} from "../../src/compliance/modules/DividendDistributor.sol";
import {LockupModule} from "../../src/compliance/modules/LockupModule.sol";
import {ISecurityToken} from "../../src/interfaces/ISecurityToken.sol";
import {IDividendDistributor} from "../../src/interfaces/IDividendDistributor.sol";
import {MockCurrency} from "../helpers/MockCurrency.sol";

/**
 * @title Handler
 * @notice Drives the security token, its modules and the dividend distributor through bounded
 *         random sequences for the invariant suite.
 * @dev Four decisions shape this handler.
 *
 *      **A fixed wallet pool, two wallets per investor.** Six actors belong to three investors, two
 *      wallets each, so a forced recovery has a valid destination whenever it picks the partner
 *      wallet. The last investor's two wallets are registered in a jurisdiction the country rule
 *      can block. A seventh address, the outsider, is never registered: it only ever acts as a
 *      `transferFrom` spender, to exercise the gate's documented blind spot for spenders.
 *
 *      **Amounts are drawn by mode, not only by range.** Zero, the full balance and one wei are the
 *      amounts where the modules infer transitions, and a uniform draw almost never hits the first
 *      two. Each amount-taking action picks one of four modes (zero, full, dust, any) first.
 *
 *      **Every revert is classified.** Each action lists the custom errors it may legitimately
 *      revert with (a locked-up transfer, a frozen sender, a paused token). An expected revert is
 *      counted per action and per selector; anything else (a panic, an empty revert, an error the
 *      action cannot legitimately produce) increments `unexpectedReverts` and is kept in
 *      `lastUnexpected`, and the suite asserts that counter stays at zero. With `fail_on_revert`
 *      off, this is what keeps a broken path from hiding behind a green run.
 *
 *      **Absorbing states are toggles with a throttle.** Pausing, freezing a wallet, withdrawing an
 *      identity and blocking the jurisdiction are entered on a fraction of the draws and left on
 *      every draw that finds them set, so they stay reachable without swallowing the run.
 *
 *      Ghost state records what the system does not expose: minted, burned, deposited and claimed
 *      totals, and for each unverified actor the balance it held when it stopped being verified.
 */
contract Handler is CommonBase, StdCheats, StdUtils {
    /*//////////////////////////////////////////////////////////////
                                 SYSTEM
    //////////////////////////////////////////////////////////////*/

    SecurityToken internal immutable token;
    IdentityRegistry internal immutable registry;
    CountryRestrictionModule internal immutable countryRule;
    DividendDistributor internal immutable distributor;
    LockupModule internal immutable lockup;
    MockCurrency internal immutable currency;

    address internal immutable issuer;
    address internal immutable agent;
    address internal immutable custodian;

    /// @dev The jurisdiction the last investor's wallets are registered in, and the one the
    ///      country toggle blocks and unblocks.
    uint16 public immutable blockableCountry;

    /*//////////////////////////////////////////////////////////////
                                 ACTORS
    //////////////////////////////////////////////////////////////*/

    /// @dev Six wallets, three investors: wallets 2k and 2k+1 share an investor id.
    address[6] public actors;

    /// @dev Never registered, never holds; only ever a `transferFrom` spender.
    address public immutable outsider;

    mapping(address actor => bytes32 id) public investorIdOf;
    mapping(address actor => uint16 code) public countryOf;

    /*//////////////////////////////////////////////////////////////
                               GHOST STATE
    //////////////////////////////////////////////////////////////*/

    uint256 public ghostMinted;
    uint256 public ghostBurned;
    uint256 public ghostDeposited;
    uint256 public ghostClaimed;

    /// @dev Successful recoveries after which the destination's lockup start was not the earlier
    ///      of the two wallets' starts, or the lost wallet kept a clock. Must stay zero.
    uint256 public ghostRecoveryClockViolations;

    /// @dev Successful claims by a holder that was fully frozen or unverified at the time. Must
    ///      stay zero.
    uint256 public ghostBlockedClaimsPaid;

    /// @dev Whether the actor was unverified at the end of the last action, and its balance at the
    ///      moment it became so. An unverified wallet can be burned from or recovered out of, but
    ///      nothing can add to it.
    mapping(address actor => bool) public ghostUnverified;
    mapping(address actor => uint256) public ghostBalanceWhenUnverified;

    /*//////////////////////////////////////////////////////////////
                         CALL AND REVERT ACCOUNTING
    //////////////////////////////////////////////////////////////*/

    string[] internal _actionNames;
    mapping(bytes32 action => uint256) public attempts;
    mapping(bytes32 action => uint256) public successes;
    mapping(bytes32 action => mapping(bytes4 selector => bool)) internal _expected;
    mapping(bytes32 action => mapping(bytes4 selector => uint256)) public revertsBySelector;
    mapping(bytes32 action => bytes4[]) internal _seenSelectors;

    uint256 public unexpectedReverts;
    bytes public lastUnexpected;
    string public lastUnexpectedAction;

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(
        SecurityToken token_,
        IdentityRegistry registry_,
        CountryRestrictionModule countryRule_,
        DividendDistributor distributor_,
        LockupModule lockup_,
        MockCurrency currency_,
        address[3] memory operators, // issuer, agent, custodian
        address[6] memory actors_,
        bytes32[6] memory ids_,
        uint16[6] memory countries_,
        uint16 blockableCountry_,
        address outsider_
    ) {
        token = token_;
        registry = registry_;
        countryRule = countryRule_;
        distributor = distributor_;
        lockup = lockup_;
        currency = currency_;
        issuer = operators[0];
        agent = operators[1];
        custodian = operators[2];
        blockableCountry = blockableCountry_;
        outsider = outsider_;
        actors = actors_;
        for (uint256 i; i < actors_.length; ++i) {
            investorIdOf[actors_[i]] = ids_[i];
            countryOf[actors_[i]] = countries_[i];
        }

        bytes4[7] memory gate = [
            ISecurityToken.RecipientNotVerified.selector,
            ISecurityToken.SenderNotVerified.selector,
            ISecurityToken.RecipientAddressFrozen.selector,
            ISecurityToken.SenderAddressFrozen.selector,
            ISecurityToken.InsufficientUnfrozenBalance.selector,
            ISecurityToken.ComplianceCheckFailed.selector,
            Pausable.EnforcedPause.selector
        ];

        _register("mint");
        _expect("mint", ISecurityToken.RecipientNotVerified.selector);
        _expect("mint", ISecurityToken.RecipientAddressFrozen.selector);
        _expect("mint", ISecurityToken.ComplianceCheckFailed.selector);
        _expect("mint", Pausable.EnforcedPause.selector);

        _register("burn");
        _expect("burn", Pausable.EnforcedPause.selector);

        _register("transfer");
        _register("transferFrom");
        for (uint256 i; i < gate.length; ++i) {
            _expect("transfer", gate[i]);
            _expect("transferFrom", gate[i]);
        }
        _expect("transferFrom", IERC20Errors.ERC20InsufficientAllowance.selector);

        _register("approve");
        _register("setAddressFrozen");
        _register("freezePartialTokens");
        _register("unfreezePartialTokens");
        _register("togglePause");

        _register("forcedRecovery");
        _expect("forcedRecovery", ISecurityToken.RecoveryToSameWallet.selector);
        _expect("forcedRecovery", ISecurityToken.NewWalletNotVerified.selector);
        _expect("forcedRecovery", ISecurityToken.RecoveryAcrossInvestors.selector);
        _expect("forcedRecovery", ISecurityToken.NothingToRecover.selector);

        _register("toggleIdentity");
        _register("toggleCountry");

        _register("deposit");
        _expect("deposit", IDividendDistributor.NoSupply.selector);

        _register("claim");
        _expect("claim", IDividendDistributor.NothingToClaim.selector);
        _expect("claim", IDividendDistributor.ClaimantFrozen.selector);
        _expect("claim", IDividendDistributor.ClaimantNotVerified.selector);

        _register("warp");
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _register(string memory action) internal {
        _actionNames.push(action);
    }

    function _expect(string memory action, bytes4 selector) internal {
        _expected[keccak256(bytes(action))][selector] = true;
    }

    function _attempt(string memory action) internal {
        ++attempts[keccak256(bytes(action))];
    }

    function _succeeded(string memory action) internal {
        ++successes[keccak256(bytes(action))];
    }

    /// @dev Classifies a caught revert: counted under its selector if the action may produce it,
    ///      otherwise recorded as unexpected.
    function _reverted(string memory action, bytes memory err) internal {
        bytes32 key = keccak256(bytes(action));
        bytes4 selector = err.length >= 4 ? bytes4(err) : bytes4(0);
        if (!_expected[key][selector]) {
            _unexpected(action, err);
            return;
        }
        if (revertsBySelector[key][selector] == 0) _seenSelectors[key].push(selector);
        ++revertsBySelector[key][selector];
    }

    function _unexpected(string memory action, bytes memory err) internal {
        ++unexpectedReverts;
        lastUnexpected = err;
        lastUnexpectedAction = action;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[bound(seed, 0, actors.length - 1)];
    }

    /// @dev The first actor at or after `start` (wrapping) holding a balance, or `start` if none.
    function _firstHolderFrom(uint256 start) internal view returns (uint256) {
        for (uint256 k; k < actors.length; ++k) {
            uint256 i = (start + k) % actors.length;
            if (token.balanceOf(actors[i]) != 0) return i;
        }
        return start;
    }

    /// @dev The first actor at or after `start` (wrapping) with a claimable amount, or `start`.
    function _firstClaimantFrom(uint256 start) internal view returns (uint256) {
        for (uint256 k; k < actors.length; ++k) {
            uint256 i = (start + k) % actors.length;
            if (distributor.claimable(actors[i]) != 0) return i;
        }
        return start;
    }

    /// @dev Picks an amount by mode: zero, the whole of `max`, one wei, or anything up to `max`.
    function _amount(uint256 mode, uint256 raw, uint256 max) internal pure returns (uint256) {
        uint256 m = mode % 4;
        if (m == 0 || max == 0) return 0;
        if (m == 1) return max;
        if (m == 2) return 1;
        return raw % (max + 1);
    }

    /// @dev Records the balance of every actor at the moment it stops being verified, and forgets
    ///      it once the actor is verified again. Runs after every action, so a silent transition
    ///      (a KYC expiring during a warp) is captured before the next action can move tokens.
    function _trackVerification() internal {
        for (uint256 i; i < actors.length; ++i) {
            address a = actors[i];
            bool verified = registry.isVerified(a);
            if (!verified && !ghostUnverified[a]) {
                ghostUnverified[a] = true;
                ghostBalanceWhenUnverified[a] = token.balanceOf(a);
            } else if (verified && ghostUnverified[a]) {
                ghostUnverified[a] = false;
            }
        }
    }

    modifier tracked() {
        _;
        _trackVerification();
    }

    /*//////////////////////////////////////////////////////////////
                            TOKEN MOVEMENTS
    //////////////////////////////////////////////////////////////*/

    function mint(uint256 toSeed, uint256 mode, uint256 raw) external tracked {
        address to = _actor(toSeed);
        uint256 amount = _amount(mode, raw, 1_000_000e18);
        _attempt("mint");
        vm.prank(issuer);
        try token.mint(to, amount) {
            ghostMinted += amount;
            _succeeded("mint");
        } catch (bytes memory err) {
            _reverted("mint", err);
        }
    }

    /// @dev The issuer may burn through a freeze, and may burn zero from a wallet holding nothing.
    function burn(uint256 fromSeed, uint256 mode, uint256 raw) external tracked {
        address from = _actor(fromSeed);
        uint256 amount = _amount(mode, raw, token.balanceOf(from));
        _attempt("burn");
        vm.prank(issuer);
        try token.burn(from, amount) {
            ghostBurned += amount;
            _succeeded("burn");
        } catch (bytes memory err) {
            _reverted("burn", err);
        }
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 mode, uint256 raw) external tracked {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 amount = _amount(mode, raw, token.balanceOf(from));
        _attempt("transfer");
        vm.prank(from);
        try token.transfer(to, amount) {
            _succeeded("transfer");
        } catch (bytes memory err) {
            _reverted("transfer", err);
        }
    }

    /// @dev The spender is any actor or the unregistered outsider. Allowances are unbounded
    ///      in size, so an allowance shortfall arises only when the owner re-approved a smaller one.
    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 mode, uint256 raw) external tracked {
        address owner = _actor(ownerSeed);
        address spender = bound(spenderSeed, 0, actors.length) == actors.length ? outsider : _actor(spenderSeed);
        uint256 amount = mode % 2 == 0 ? type(uint256).max : raw % 1_000_000e18;
        _attempt("approve");
        vm.prank(owner);
        try token.approve(spender, amount) {
            _succeeded("approve");
        } catch (bytes memory err) {
            _reverted("approve", err);
        }
    }

    function transferFrom(uint256 spenderSeed, uint256 fromSeed, uint256 toSeed, uint256 mode, uint256 raw)
        external
        tracked
    {
        address spender = bound(spenderSeed, 0, actors.length) == actors.length ? outsider : _actor(spenderSeed);
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 amount = _amount(mode, raw, token.balanceOf(from));
        _attempt("transferFrom");
        vm.prank(spender);
        try token.transferFrom(from, to, amount) {
            _succeeded("transferFrom");
        } catch (bytes memory err) {
            _reverted("transferFrom", err);
        }
    }

    /*//////////////////////////////////////////////////////////////
                            FREEZE CONTROLS
    //////////////////////////////////////////////////////////////*/

    /// @dev Freezing is throttled to one draw in four; unfreezing a frozen wallet is not.
    function setAddressFrozen(uint256 whoSeed, uint256 throttleSeed) external tracked {
        address who = _actor(whoSeed);
        bool freeze = !token.isFrozen(who);
        if (freeze && bound(throttleSeed, 0, 3) != 0) return;
        _attempt("setAddressFrozen");
        vm.prank(agent);
        try token.setAddressFrozen(who, freeze) {
            _succeeded("setAddressFrozen");
        } catch (bytes memory err) {
            _reverted("setAddressFrozen", err);
        }
    }

    function freezePartialTokens(uint256 whoSeed, uint256 mode, uint256 raw) external tracked {
        address who = _actor(whoSeed);
        uint256 amount = _amount(mode, raw, token.balanceOf(who) - token.frozenTokens(who));
        _attempt("freezePartialTokens");
        vm.prank(agent);
        try token.freezePartialTokens(who, amount) {
            _succeeded("freezePartialTokens");
        } catch (bytes memory err) {
            _reverted("freezePartialTokens", err);
        }
    }

    function unfreezePartialTokens(uint256 whoSeed, uint256 mode, uint256 raw) external tracked {
        address who = _actor(whoSeed);
        uint256 amount = _amount(mode, raw, token.frozenTokens(who));
        _attempt("unfreezePartialTokens");
        vm.prank(agent);
        try token.unfreezePartialTokens(who, amount) {
            _succeeded("unfreezePartialTokens");
        } catch (bytes memory err) {
            _reverted("unfreezePartialTokens", err);
        }
    }

    /// @dev Entering a pause is throttled to one draw in ten; leaving one never is. As two
    ///      independent actions the run would spend most of its depth paused.
    function togglePause(uint256 seed) external tracked {
        bool isPaused = token.paused();
        if (!isPaused && bound(seed, 0, 9) != 0) return;
        _attempt("togglePause");
        vm.prank(agent);
        if (isPaused) {
            try token.unpause() {
                _succeeded("togglePause");
            } catch (bytes memory err) {
                _reverted("togglePause", err);
            }
        } else {
            try token.pause() {
                _succeeded("togglePause");
            } catch (bytes memory err) {
                _reverted("togglePause", err);
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                                RECOVERY
    //////////////////////////////////////////////////////////////*/

    /// @dev Three draws in four are aimed: the lost wallet is the first actor from the seed that
    ///      holds a balance, and the destination is its partner (the same investor), which is the
    ///      case recovery exists for. The rest pick both wallets at random, so the rejections
    ///      (empty wallet, same wallet, another investor, unverified destination) stay exercised.
    function forcedRecovery(uint256 lostSeed, uint256 newSeed, uint256 aimSeed) external tracked {
        bool aimed = bound(aimSeed, 0, 3) != 0;
        uint256 lostIndex = bound(lostSeed, 0, actors.length - 1);
        if (aimed) lostIndex = _firstHolderFrom(lostIndex);
        address lost = actors[lostIndex];
        address replacement = aimed ? actors[lostIndex ^ 1] : _actor(newSeed);
        uint64 lostStart = lockup.lockStart(lost);
        uint64 destStart = lockup.lockStart(replacement);
        uint64 expected = destStart != 0 && destStart < lostStart ? destStart : lostStart;
        _attempt("forcedRecovery");
        vm.prank(custodian);
        try token.forcedRecovery(lost, replacement) {
            // Recovery relocates a position: it must not restart, shorten or extend its lockup.
            if (lockup.lockStart(replacement) != expected || lockup.lockStart(lost) != 0) {
                ++ghostRecoveryClockViolations;
            }
            _succeeded("forcedRecovery");
        } catch (bytes memory err) {
            // Two wallets of one investor always share an investor id, removed or not, so this
            // error is only legitimate across investors.
            bool sameInvestor = investorIdOf[lost] == investorIdOf[replacement];
            if (sameInvestor && bytes4(err) == ISecurityToken.RecoveryAcrossInvestors.selector) {
                _unexpected("forcedRecovery", err);
            } else {
                _reverted("forcedRecovery", err);
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                           IDENTITY AND RULES
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Withdrawing an identity (throttled to one draw in five) and restoring it (never
     *      throttled). The restored record carries the actor's original investor id and country,
     *      so recovery destinations and the jurisdiction split survive a withdrawal. A wallet
     *      whose KYC expired is restored the same way.
     */
    function toggleIdentity(uint256 whoSeed, uint256 throttleSeed) external tracked {
        address who = _actor(whoSeed);
        bool verified = registry.isVerified(who);
        if (verified && bound(throttleSeed, 0, 4) != 0) return;
        _attempt("toggleIdentity");
        vm.startPrank(agent);
        if (verified) {
            try registry.removeIdentity(who) {
                _succeeded("toggleIdentity");
            } catch (bytes memory err) {
                _reverted("toggleIdentity", err);
            }
        } else {
            try registry.registerIdentity(
                who, countryOf[who], true, uint64(block.timestamp + 3650 days), investorIdOf[who]
            ) {
                _succeeded("toggleIdentity");
            } catch (bytes memory err) {
                _reverted("toggleIdentity", err);
            }
        }
        vm.stopPrank();
    }

    /// @dev Blocking the jurisdiction is throttled to one draw in five; unblocking never is.
    function toggleCountry(uint256 throttleSeed) external tracked {
        bool restricted = countryRule.isRestricted(blockableCountry);
        if (!restricted && bound(throttleSeed, 0, 4) != 0) return;
        _attempt("toggleCountry");
        vm.prank(agent);
        try countryRule.setCountryRestricted(blockableCountry, !restricted) {
            _succeeded("toggleCountry");
        } catch (bytes memory err) {
            _reverted("toggleCountry", err);
        }
    }

    /*//////////////////////////////////////////////////////////////
                               DIVIDENDS
    //////////////////////////////////////////////////////////////*/

    /// @dev Income in a 6-decimal currency, from one unit up to a thousand whole units.
    function deposit(uint256 raw) external tracked {
        uint256 amount = bound(raw, 1, 1_000e6);
        _attempt("deposit");
        vm.prank(issuer);
        try distributor.deposit(amount) {
            ghostDeposited += amount;
            _succeeded("deposit");
        } catch (bytes memory err) {
            _reverted("deposit", err);
        }
    }

    /// @dev Any actor claims, including frozen and unverified ones, which must be refused. Three
    ///      draws in four start from the seed and take the first actor with something to claim,
    ///      so paid claims are not drowned by empty ones; the rest keep the seed's actor as drawn.
    function claim(uint256 whoSeed, uint256 aimSeed) external tracked {
        uint256 index = bound(whoSeed, 0, actors.length - 1);
        if (bound(aimSeed, 0, 3) != 0) index = _firstClaimantFrom(index);
        address who = actors[index];
        uint256 before = currency.balanceOf(who);
        bool blocked = token.isFrozen(who) || !registry.isVerified(who);
        _attempt("claim");
        vm.prank(who);
        try distributor.claim(who) {
            if (blocked) ++ghostBlockedClaimsPaid;
            ghostClaimed += currency.balanceOf(who) - before;
            _succeeded("claim");
        } catch (bytes memory err) {
            _reverted("claim", err);
        }
    }

    /*//////////////////////////////////////////////////////////////
                                  TIME
    //////////////////////////////////////////////////////////////*/

    /// @dev Time passes, so lockups expire and, occasionally, a KYC attestation does.
    function warp(uint256 secondsAhead) external tracked {
        _attempt("warp");
        vm.warp(block.timestamp + bound(secondsAhead, 1 hours, 30 days));
        _succeeded("warp");
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function actionCount() external view returns (uint256) {
        return _actionNames.length;
    }

    function actionName(uint256 i) external view returns (string memory) {
        return _actionNames[i];
    }

    function seenSelectors(string memory action) external view returns (bytes4[] memory) {
        return _seenSelectors[keccak256(bytes(action))];
    }

    function attemptsOf(string memory action) external view returns (uint256) {
        return attempts[keccak256(bytes(action))];
    }

    function successesOf(string memory action) external view returns (uint256) {
        return successes[keccak256(bytes(action))];
    }

    function revertsOf(string memory action, bytes4 selector) external view returns (uint256) {
        return revertsBySelector[keccak256(bytes(action))][selector];
    }
}
