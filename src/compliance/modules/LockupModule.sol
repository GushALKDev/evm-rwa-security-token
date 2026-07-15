// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {AbstractComplianceModule} from "./AbstractComplianceModule.sol";
import {IComplianceModule} from "../../interfaces/IComplianceModule.sol";
import {Roles} from "../../Roles.sol";

/**
 * @title LockupModule
 * @notice Enforces a holding period: an investor cannot send tokens until their lockup elapses.
 * @dev Models the holding period a private placement imposes before an investor may resell.
 *
 *      The clock starts on INITIAL acquisition (the 0 to positive transition) and is not reset by
 *      later receipts. That choice is a security property, not a convenience:
 *
 *      A strict per-acquisition lockup (every receipt restarts the clock) is griefable. Anyone
 *      could send a victim 1 wei of token and re-lock their entire position, for free, forever.
 *      A lockup a third party can trigger against you at no cost is a denial of service wearing
 *      a compliance costume.
 *
 *      The strictly correct reading of "12 months from acquisition" would lock each PARCEL
 *      separately, each with its own clock, which is exactly what ERC-1400 partitions (tranches)
 *      are for. Those are deliberately out of scope here (see the README), and without them the
 *      per-acquisition model cannot be implemented safely. So: clock from initial acquisition,
 *      cleared when the investor exits to zero, and the anchored terms document says "from
 *      initial acquisition" to match.
 */
contract LockupModule is AbstractComplianceModule, AccessControl {
    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Emitted when the lockup duration changes.
     * @param lockupPeriod The new duration in seconds.
     */
    event LockupPeriodUpdated(uint64 lockupPeriod);

    /**
     * @notice Emitted when an investor's lockup clock starts.
     * @param investor The investor.
     * @param lockStart The timestamp the clock started.
     * @param unlocksAt The timestamp the investor becomes free to send.
     */
    event LockupStarted(address indexed investor, uint64 lockStart, uint64 unlocksAt);

    /**
     * @notice Emitted when an investor exits to zero and their clock is cleared.
     * @param investor The investor.
     */
    event LockupCleared(address indexed investor);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Thrown when the zero address is supplied where a real account is required.
    error ZeroAddress();

    /*//////////////////////////////////////////////////////////////
                                 STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @dev The token whose balances define acquisition.
    IERC20 private immutable _token;

    /// @dev Seconds an investor must hold before they may send.
    uint64 private _lockupPeriod;

    /// @dev When each investor's clock started. Zero means no position and no clock.
    mapping(address investor => uint64 lockStart) private _lockStart;

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Deploys the module.
     * @param compliance_ The compliance engine that will call the hooks.
     * @param token_ The token whose balances define acquisition.
     * @param issuer The account receiving DEFAULT_ADMIN_ROLE.
     * @param agent The account receiving AGENT_ROLE.
     * @param lockupPeriod_ The holding period in seconds. Zero disables the rule.
     */
    constructor(address compliance_, address token_, address issuer, address agent, uint64 lockupPeriod_)
        AbstractComplianceModule(compliance_)
    {
        if (token_ == address(0) || issuer == address(0) || agent == address(0)) revert ZeroAddress();

        _token = IERC20(token_);
        _lockupPeriod = lockupPeriod_;
        _grantRole(DEFAULT_ADMIN_ROLE, issuer);
        _grantRole(Roles.AGENT_ROLE, agent);

        emit LockupPeriodUpdated(lockupPeriod_);
    }

    /*//////////////////////////////////////////////////////////////
                              RULE ADMIN
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Updates the holding period.
     * @dev Restricted to AGENT. Applies to existing clocks: shortening the period releases
     *      investors early, lengthening it extends them, since the check is evaluated against the
     *      current period rather than the one in force at acquisition. That is the simple
     *      reading; a production instrument would likely snapshot the period per investor.
     * @param lockupPeriod_ The new duration in seconds.
     */
    function setLockupPeriod(uint64 lockupPeriod_) external onlyRole(Roles.AGENT_ROLE) {
        _lockupPeriod = lockupPeriod_;

        emit LockupPeriodUpdated(lockupPeriod_);
    }

    /*//////////////////////////////////////////////////////////////
                                  CHECK
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IComplianceModule
    function moduleCheck(address from, address, uint256) external view returns (bool) {
        // A mint is an acquisition, not a disposal: nothing to lock.
        if (from == address(0)) return true;

        uint64 start = _lockStart[from];

        // No clock means no position was ever acquired, so there is nothing this rule restrains.
        if (start == 0) return true;

        return block.timestamp >= start + _lockupPeriod;
    }

    /*//////////////////////////////////////////////////////////////
                             LIFECYCLE HOOKS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IComplianceModule
    function moduleTransferred(address from, address to, uint256 amount) external onlyCompliance {
        _startClockIfNew(to, amount);
        _clearClockIfExited(from);
    }

    /// @inheritdoc IComplianceModule
    function moduleCreated(address to, uint256 amount) external onlyCompliance {
        // Primary issuance is the archetypal acquisition, so mint starts the clock through the
        // same path as a transfer.
        _startClockIfNew(to, amount);
    }

    /// @inheritdoc IComplianceModule
    function moduleDestroyed(address from, uint256) external onlyCompliance {
        _clearClockIfExited(from);
    }

    /*//////////////////////////////////////////////////////////////
                                  VIEWS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice The holding period in seconds.
     * @return The period.
     */
    function lockupPeriod() external view returns (uint64) {
        return _lockupPeriod;
    }

    /**
     * @notice When an investor's lockup clock started.
     * @param investor The investor.
     * @return The start timestamp, zero if no clock is running.
     */
    function lockStart(address investor) external view returns (uint64) {
        return _lockStart[investor];
    }

    /**
     * @notice When an investor becomes free to send.
     * @param investor The investor.
     * @return The unlock timestamp, zero if no clock is running.
     */
    function unlocksAt(address investor) external view returns (uint64) {
        uint64 start = _lockStart[investor];
        if (start == 0) return 0;

        return start + _lockupPeriod;
    }

    /**
     * @notice The token whose balances define acquisition.
     * @return The token address.
     */
    function token() external view returns (address) {
        return address(_token);
    }

    /// @inheritdoc IComplianceModule
    function name() external pure returns (string memory) {
        return "LockupModule";
    }

    /*//////////////////////////////////////////////////////////////
                                INTERNAL
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Starts a clock only on the 0 to positive transition. The lockStart == 0 guard is the
     *      anti-griefing property in one line: an existing clock is never overwritten, so a dust
     *      transfer cannot re-lock a position.
     * @param to The recipient.
     * @param amount The amount received.
     */
    function _startClockIfNew(address to, uint256 amount) private {
        if (amount == 0) return;
        // Hooks run after balances move, so this equality identifies a recipient who held zero.
        if (_token.balanceOf(to) != amount) return;
        if (_lockStart[to] != 0) return;

        uint64 start = uint64(block.timestamp);
        _lockStart[to] = start;

        emit LockupStarted(to, start, start + _lockupPeriod);
    }

    /**
     * @dev Clears the clock when an investor exits to zero. Without this, an investor who sold
     *      out and later bought back would keep their original, long-expired clock and would
     *      never be locked again.
     * @param from The sender.
     */
    function _clearClockIfExited(address from) private {
        if (from == address(0)) return;
        if (_token.balanceOf(from) != 0) return;
        if (_lockStart[from] == 0) return;

        delete _lockStart[from];

        emit LockupCleared(from);
    }
}
