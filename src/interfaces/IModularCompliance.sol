// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IModularCompliance
 * @notice The compliance engine: composes a set of rule modules behind one check, and fans
 *         lifecycle events out to them.
 * @dev Simplified subset of the ERC-3643 ModularCompliance. The token holds a reference to this
 *      engine and never to individual rules, so the rule set is a deployment and governance
 *      concern rather than a code change.
 *
 *      canTransfer here covers only the modular rules. The token composes it with identity,
 *      freeze and pause checks: the token-level gate is a superset of this one.
 */
interface IModularCompliance {
    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Emitted when a rule module is added to the engine.
     * @param module The module address.
     */
    event ModuleAdded(address indexed module);

    /**
     * @notice Emitted when a rule module is removed from the engine.
     * @param module The module address.
     */
    event ModuleRemoved(address indexed module);

    /**
     * @notice Emitted when the engine is bound to a token.
     * @param token The token address.
     */
    event TokenBound(address indexed token);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Thrown when the zero address is supplied where a real account is required.
    error ZeroAddress();

    /// @notice Thrown when a lifecycle hook is called by anything other than the bound token.
    error OnlyToken(address caller, address token);

    /// @notice Thrown when adding a module that is already registered.
    error ModuleAlreadyAdded(address module);

    /// @notice Thrown when removing a module that is not registered.
    error ModuleNotFound(address module);

    /// @notice Thrown when adding a module bound to a different compliance engine.
    error ModuleNotBound(address module);

    /// @notice Thrown when binding a token to an engine that already has one.
    error TokenAlreadyBound(address token);

    /*//////////////////////////////////////////////////////////////
                              MODULE ADMIN
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Adds a rule module to the engine.
     * @dev Restricted to the issuer (default admin). The module must already point at this
     *      engine, otherwise its lifecycle hooks would reject the engine's calls.
     * @param module The module to add.
     */
    function addModule(address module) external;

    /**
     * @notice Removes a rule module from the engine.
     * @dev Restricted to the issuer (default admin). Any state the module accumulated is
     *      abandoned, not migrated: re-adding a stateful module gives it stale state.
     * @param module The module to remove.
     */
    function removeModule(address module) external;

    /**
     * @notice Binds the engine to the token whose lifecycle hooks it will accept.
     * @dev Restricted to the issuer (default admin), and settable once: rebinding a live engine
     *      would let a second token corrupt the rule state of the first.
     * @param token The token address.
     */
    function bindToken(address token) external;

    /*//////////////////////////////////////////////////////////////
                             LIFECYCLE HOOKS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Notifies every module that a transfer settled.
     * @dev Restricted to the bound token, called after balances move.
     * @param from The sender.
     * @param to The recipient.
     * @param amount The transfer amount.
     */
    function transferred(address from, address to, uint256 amount) external;

    /**
     * @notice Notifies every module that tokens were minted.
     * @dev Restricted to the bound token, called after balances move.
     * @param to The recipient.
     * @param amount The minted amount.
     */
    function created(address to, uint256 amount) external;

    /**
     * @notice Notifies every module that tokens were burned.
     * @dev Restricted to the bound token, called after balances move.
     * @param from The account burned from.
     * @param amount The burned amount.
     */
    function destroyed(address from, uint256 amount) external;

    /*//////////////////////////////////////////////////////////////
                                  VIEWS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Evaluates every registered module against a transfer.
     * @dev Short-circuits on the first rule that rejects. Covers modular rules only, see the
     *      note on the interface.
     * @param from The sender, or the zero address for a mint.
     * @param to The recipient, or the zero address for a burn.
     * @param amount The transfer amount.
     * @return True if every module permits the transfer.
     */
    function canTransfer(address from, address to, uint256 amount) external view returns (bool);

    /**
     * @notice Returns the registered rule modules.
     * @return The module addresses.
     */
    function modules() external view returns (address[] memory);

    /**
     * @notice Whether a module is registered.
     * @param module The module address.
     * @return True if registered.
     */
    function isModuleRegistered(address module) external view returns (bool);

    /**
     * @notice The token this engine is bound to.
     * @return The token address.
     */
    function token() external view returns (address);
}
