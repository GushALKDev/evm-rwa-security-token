// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {AbstractComplianceModule} from "./AbstractComplianceModule.sol";
import {IComplianceModule} from "../../interfaces/IComplianceModule.sol";
import {Roles} from "../../Roles.sol";

/**
 * @title MaxHoldersModule
 * @notice Caps the number of distinct token holders.
 * @dev Models a regulatory holder cap (for example the investor-count thresholds that change an
 *      instrument's reporting or registration obligations in several jurisdictions). Exceeding
 *      it is not a technical failure, it is a legal one, so the rule blocks the transfer that
 *      would cross the line.
 *
 *      The count is maintained incrementally in the lifecycle hooks. Enumerating holders on
 *      every transfer would be O(n) gas and would eventually make the token unusable at exactly
 *      the moment it succeeds, which is a self-defeating design.
 *
 *      Correctness of the count rests on one subtlety: the hooks run AFTER balances move, so
 *      this module cannot read a pre-transfer balance. It infers the transitions instead:
 *      balanceOf(to) == amount means the recipient came from zero (a new holder), and
 *      balanceOf(from) == 0 means the sender emptied out (a holder left). Both are exact, not
 *      heuristic, because the hook is called in the same transaction as the balance change.
 */
contract MaxHoldersModule is AbstractComplianceModule, AccessControl {
    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Emitted when the holder cap changes.
     * @param maxHolders The new cap.
     */
    event MaxHoldersUpdated(uint256 maxHolders);

    /**
     * @notice Emitted when the tracked holder count changes.
     * @param holderCount The new count.
     */
    event HolderCountUpdated(uint256 holderCount);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Thrown when the zero address is supplied where a real account is required.
    error ZeroAddress();

    /// @notice Thrown when setting a cap below the current holder count.
    error MaxHoldersBelowCurrentCount(uint256 requested, uint256 current);

    /// @notice Thrown when setting a cap of zero, which would freeze the token permanently.
    error MaxHoldersZero();

    /*//////////////////////////////////////////////////////////////
                                 STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @dev The token whose balances define holder status.
    IERC20 private immutable _token;

    /// @dev The cap on distinct holders.
    uint256 private _maxHolders;

    /// @dev The current number of distinct holders, maintained incrementally.
    uint256 private _holderCount;

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Deploys the module.
     * @param compliance_ The compliance engine that will call the hooks.
     * @param token_ The token whose balances define holder status.
     * @param issuer The account receiving DEFAULT_ADMIN_ROLE.
     * @param agent The account receiving AGENT_ROLE.
     * @param maxHolders_ The initial cap.
     */
    constructor(address compliance_, address token_, address issuer, address agent, uint256 maxHolders_)
        AbstractComplianceModule(compliance_)
    {
        if (token_ == address(0) || issuer == address(0) || agent == address(0)) revert ZeroAddress();
        if (maxHolders_ == 0) revert MaxHoldersZero();

        _token = IERC20(token_);
        _maxHolders = maxHolders_;
        _grantRole(DEFAULT_ADMIN_ROLE, issuer);
        _grantRole(Roles.AGENT_ROLE, agent);

        emit MaxHoldersUpdated(maxHolders_);
    }

    /*//////////////////////////////////////////////////////////////
                              RULE ADMIN
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Updates the holder cap.
     * @dev Restricted to AGENT. Cannot be set below the current count: doing so would put the
     *      token in a state that is already illegal, with no transfer able to fix it. Reducing
     *      the cap requires the count to come down first (through burns or consolidation).
     * @param maxHolders_ The new cap.
     */
    function setMaxHolders(uint256 maxHolders_) external onlyRole(Roles.AGENT_ROLE) {
        if (maxHolders_ == 0) revert MaxHoldersZero();
        if (maxHolders_ < _holderCount) revert MaxHoldersBelowCurrentCount(maxHolders_, _holderCount);

        _maxHolders = maxHolders_;

        emit MaxHoldersUpdated(maxHolders_);
    }

    /*//////////////////////////////////////////////////////////////
                                  CHECK
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IComplianceModule
    function moduleCheck(address from, address to, uint256 amount) external view returns (bool) {
        // A burn removes supply and can only reduce the holder count.
        if (to == address(0)) return true;

        // An existing holder receiving more tokens does not change the count.
        if (_token.balanceOf(to) != 0) return true;

        // A new holder is about to appear. If the sender is emptying out in the same transfer,
        // the count is unchanged: one holder replaces another. Mints (from == 0) never offset.
        bool senderLeaves = from != address(0) && _token.balanceOf(from) == amount;
        if (senderLeaves) return true;

        return _holderCount < _maxHolders;
    }

    /*//////////////////////////////////////////////////////////////
                             LIFECYCLE HOOKS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IComplianceModule
    function moduleTransferred(address from, address to, uint256 amount) external onlyCompliance {
        // A self-transfer leaves the balance exactly as it was, so no holder joined or left. It
        // must be discarded before the inference below: with from == to, a full-balance send makes
        // balanceOf(to) == amount read as "came from zero" while the sender is plainly not empty,
        // so the two signals fail to cancel and the count would rise for a holder who never
        // appeared. Anyone could then inflate the count at will and exhaust the cap.
        if (from == to) return;

        // Hooks run after balances move: balanceOf(to) == amount means "to" came from zero.
        bool recipientJoined = _token.balanceOf(to) == amount && amount != 0;
        bool senderLeft = _token.balanceOf(from) == 0;

        if (recipientJoined == senderLeft) return; // both or neither: count is unchanged

        _holderCount = recipientJoined ? _holderCount + 1 : _holderCount - 1;

        emit HolderCountUpdated(_holderCount);
    }

    /// @inheritdoc IComplianceModule
    function moduleCreated(address to, uint256 amount) external onlyCompliance {
        // A mint has no sender to offset the new holder.
        if (_token.balanceOf(to) != amount || amount == 0) return;

        ++_holderCount;

        emit HolderCountUpdated(_holderCount);
    }

    /// @inheritdoc IComplianceModule
    function moduleDestroyed(address from, uint256) external onlyCompliance {
        // A burn that empties an account removes a holder.
        if (_token.balanceOf(from) != 0) return;

        --_holderCount;

        emit HolderCountUpdated(_holderCount);
    }

    /*//////////////////////////////////////////////////////////////
                                  VIEWS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice The holder cap.
     * @return The cap.
     */
    function maxHolders() external view returns (uint256) {
        return _maxHolders;
    }

    /**
     * @notice The current number of distinct holders.
     * @return The count.
     */
    function holderCount() external view returns (uint256) {
        return _holderCount;
    }

    /**
     * @notice The token whose balances define holder status.
     * @return The token address.
     */
    function token() external view returns (address) {
        return address(_token);
    }

    /// @inheritdoc IComplianceModule
    function name() external pure returns (string memory) {
        return "MaxHoldersModule";
    }
}
