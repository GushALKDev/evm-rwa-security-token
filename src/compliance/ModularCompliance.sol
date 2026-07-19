// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {IModularCompliance} from "../interfaces/IModularCompliance.sol";
import {IComplianceModule} from "../interfaces/IComplianceModule.sol";

/**
 * @title ModularCompliance
 * @notice The compliance engine: composes a set of rule modules behind one check and fans the
 *         token's lifecycle events out to them.
 * @dev The token holds a reference to this engine and never to individual modules, so changing
 *      the rule set is a governance action (add/remove a module) rather than a token upgrade.
 *      This is the seam that makes the ruleset pluggable.
 *
 *      Two authorization boundaries meet here and must not be confused:
 *      - Module admin (add, remove, bind) is the ISSUER's, gated by DEFAULT_ADMIN_ROLE.
 *      - Lifecycle hooks are the bound TOKEN's, gated by onlyToken. Only the token that owns the
 *        balances may tell the engine a transfer settled, or a module's state could be
 *        desynchronized from the real balances and the rule walked through afterwards.
 *
 *      bindToken is settable once. Rebinding a live engine would let a second token drive the
 *      lifecycle hooks of modules whose state was accumulated from the first, corrupting every
 *      stateful rule.
 */
contract ModularCompliance is IModularCompliance, AccessControl {
    using EnumerableSet for EnumerableSet.AddressSet;

    /*//////////////////////////////////////////////////////////////
                                 STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @dev The registered rule modules. A set so add/remove/lookup are O(1) and duplicates are
    ///      impossible, while modules() can still enumerate for tooling and the hooks.
    EnumerableSet.AddressSet private _modules;

    /// @dev The token whose lifecycle hooks this engine accepts. Set once by bindToken.
    address private _token;

    /*//////////////////////////////////////////////////////////////
                                MODIFIERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Restricts a lifecycle hook to the bound token.
     */
    modifier onlyToken() {
        if (msg.sender != _token) revert OnlyToken(msg.sender, _token);
        _;
    }

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Deploys the engine.
     * @dev The engine must exist before its modules: each module binds to an engine address at
     *      construction, so the deployment order is engine first, then modules, then addModule.
     * @param issuer The account receiving DEFAULT_ADMIN_ROLE.
     */
    constructor(address issuer) {
        if (issuer == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, issuer);
    }

    /*//////////////////////////////////////////////////////////////
                              MODULE ADMIN
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IModularCompliance
    function addModule(address module) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (module == address(0)) revert ZeroAddress();
        // The module must already point at this engine, or its onlyCompliance hooks would reject
        // every call this engine makes and its state would silently never update.
        if (IComplianceModule(module).compliance() != address(this)) revert ModuleNotBound(module);
        if (!_modules.add(module)) revert ModuleAlreadyAdded(module);

        emit ModuleAdded(module);
    }

    /// @inheritdoc IModularCompliance
    function removeModule(address module) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!_modules.remove(module)) revert ModuleNotFound(module);

        emit ModuleRemoved(module);
    }

    /// @inheritdoc IModularCompliance
    function bindToken(address token_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token_ == address(0)) revert ZeroAddress();
        if (_token != address(0)) revert TokenAlreadyBound(_token);

        _token = token_;

        emit TokenBound(token_);
    }

    /*//////////////////////////////////////////////////////////////
                             LIFECYCLE HOOKS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IModularCompliance
    function transferred(address from, address to, uint256 amount) external onlyToken {
        uint256 length = _modules.length();
        for (uint256 i; i < length; ++i) {
            IComplianceModule(_modules.at(i)).moduleTransferred(from, to, amount);
        }
    }

    /// @inheritdoc IModularCompliance
    function created(address to, uint256 amount) external onlyToken {
        uint256 length = _modules.length();
        for (uint256 i; i < length; ++i) {
            IComplianceModule(_modules.at(i)).moduleCreated(to, amount);
        }
    }

    /// @inheritdoc IModularCompliance
    function destroyed(address from, uint256 amount) external onlyToken {
        uint256 length = _modules.length();
        for (uint256 i; i < length; ++i) {
            IComplianceModule(_modules.at(i)).moduleDestroyed(from, amount);
        }
    }

    /*//////////////////////////////////////////////////////////////
                                  VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IModularCompliance
    function canTransfer(address from, address to, uint256 amount) external view returns (bool) {
        uint256 length = _modules.length();
        for (uint256 i; i < length; ++i) {
            // Short-circuit on the first rejecting rule: no need to evaluate the rest.
            if (!IComplianceModule(_modules.at(i)).moduleCheck(from, to, amount)) return false;
        }
        return true;
    }

    /// @inheritdoc IModularCompliance
    function modules() external view returns (address[] memory) {
        return _modules.values();
    }

    /// @inheritdoc IModularCompliance
    function isModuleRegistered(address module) external view returns (bool) {
        return _modules.contains(module);
    }

    /// @inheritdoc IModularCompliance
    function token() external view returns (address) {
        return _token;
    }
}
