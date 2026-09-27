// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IComplianceModule
 * @notice The contract a single compliance rule must satisfy to be plugged into the engine.
 * @dev This interface is the seam that makes rules pluggable: ModularCompliance knows only this
 *      shape, never a concrete module, so rules can be added or removed without touching the
 *      token. Modules are the only place a rule is expressed.
 *
 *      Modules must be stateless with respect to the caller's identity beyond what they track
 *      themselves, and must accept lifecycle hooks from the bound engine only. A module holding
 *      state (holder counts, lockup starts) must implement created and destroyed, not only
 *      transferred, or its state drifts from reality the first time tokens are minted or burned.
 */
interface IComplianceModule {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Thrown when a lifecycle hook is called by anything other than the bound engine.
    error OnlyCompliance(address caller, address compliance);

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Emitted when the engine attaches this module (`addModule`).
     * @param compliance The engine.
     */
    event ComplianceBound(address indexed compliance);

    /**
     * @notice Emitted when the engine detaches this module (`removeModule`).
     * @param compliance The engine.
     */
    event ComplianceUnbound(address indexed compliance);

    /*//////////////////////////////////////////////////////////////
                                  CHECK
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Evaluates whether a transfer satisfies this rule.
     * @dev Must be a pure read: no state changes, no reverts on a rule violation (return false).
     *      Called on every transfer, so it must stay cheap.
     * @param from The sender, or the zero address for a mint.
     * @param to The recipient, or the zero address for a burn.
     * @param amount The transfer amount.
     * @return True if this rule permits the transfer.
     */
    function moduleCheck(address from, address to, uint256 amount) external view returns (bool);

    /*//////////////////////////////////////////////////////////////
                             LIFECYCLE HOOKS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Notifies the module that a transfer settled.
     * @dev Restricted to the bound compliance engine. Stateful modules update their state here.
     * @param from The sender.
     * @param to The recipient.
     * @param amount The transfer amount.
     */
    function moduleTransferred(address from, address to, uint256 amount) external;

    /**
     * @notice Notifies the module that tokens were minted.
     * @dev Restricted to the bound compliance engine. Separate from transferred because a mint
     *      creates supply and can create a holder without any sender.
     * @param to The recipient.
     * @param amount The minted amount.
     */
    function moduleCreated(address to, uint256 amount) external;

    /**
     * @notice Notifies the module that tokens were burned.
     * @dev Restricted to the bound compliance engine. Separate from transferred because a burn
     *      destroys supply and can remove a holder without any recipient.
     * @param from The account burned from.
     * @param amount The burned amount.
     */
    function moduleDestroyed(address from, uint256 amount) external;

    /*//////////////////////////////////////////////////////////////
                               ATTACHMENT
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Records that the engine attached this module.
     * @dev Restricted to the bound engine, which calls it from `addModule` after checking
     *      `canComplianceBind`. Follows the T-REX `IModule` shape.
     * @param compliance_ The engine.
     */
    function bindCompliance(address compliance_) external;

    /**
     * @notice Records that the engine detached this module.
     * @dev Restricted to the bound engine, which calls it from `removeModule`.
     * @param compliance_ The engine.
     */
    function unbindCompliance(address compliance_) external;

    /**
     * @notice Whether `compliance_` may attach this module now.
     * @dev A stateful module refuses once it has been attached before, since it missed every
     *      movement made while it was out, and a module that infers state from balances also
     *      refuses once the token has supply, since it would start from empty state.
     * @param compliance_ The engine asking.
     * @return True if the engine may attach this module.
     */
    function canComplianceBind(address compliance_) external view returns (bool);

    /**
     * @notice Whether this module is currently attached to `compliance_`.
     * @param compliance_ The engine.
     * @return True while attached.
     */
    function isComplianceBound(address compliance_) external view returns (bool);

    /**
     * @notice Whether this module keeps no state derived from token movements, so it can be
     *         attached, removed and attached again at any time.
     * @return True for a stateless module.
     */
    function isPlugAndPlay() external pure returns (bool);

    /*//////////////////////////////////////////////////////////////
                                  VIEWS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice The compliance engine this module is bound to.
     * @return The engine address.
     */
    function compliance() external view returns (address);

    /**
     * @notice A human readable identifier for the rule, for tooling and audit trails.
     * @return The module name.
     */
    function name() external view returns (string memory);
}
