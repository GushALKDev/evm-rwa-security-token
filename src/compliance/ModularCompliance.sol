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

    /// @dev The most modules the engine accepts, as in T-REX. Every transfer iterates the modules
    ///      in `canTransfer` and again in the hook fan-out, so the cap bounds that gas.
    uint256 public constant MAX_MODULES = 25;

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
     *      construction. The token also takes the engine in its constructor, and the modules that
     *      read balances take the token, so the deployment order is engine, registry, token, then
     *      the modules, then addModule and bindToken (see script/Deploy.s.sol).
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
        // every call this engine makes, reverting every mint, burn and transfer.
        if (IComplianceModule(module).compliance() != address(this)) revert ModuleNotBound(module);
        if (_modules.contains(module)) revert ModuleAlreadyAdded(module);
        if (_modules.length() >= MAX_MODULES) revert ModuleLimitReached(MAX_MODULES);
        // The module decides whether it can join now (the T-REX canComplianceBind shape). A module
        // that infers state from balances refuses a token with supply, since it would start from
        // empty state, and a stateful module refuses to come back after a removal, since it missed
        // every movement made while it was out.
        if (!IComplianceModule(module).canComplianceBind(address(this))) revert ModuleCannotBind(module);
        // Once a token is bound, a module that reads balances must read that token's.
        address bound = _token;
        if (bound != address(0)) _requireSameToken(module, bound);

        _modules.add(module);

        emit ModuleAdded(module);

        IComplianceModule(module).bindCompliance(address(this));
    }

    /// @inheritdoc IModularCompliance
    function removeModule(address module) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!_modules.remove(module)) revert ModuleNotFound(module);

        emit ModuleRemoved(module);

        IComplianceModule(module).unbindCompliance(address(this));
    }

    /// @inheritdoc IModularCompliance
    function bindToken(address token_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token_ == address(0)) revert ZeroAddress();
        if (_token != address(0)) revert TokenAlreadyBound(_token);
        // Modules registered before the binding must read the token being bound.
        uint256 length = _modules.length();
        for (uint256 i; i < length; ++i) {
            _requireSameToken(_modules.at(i), token_);
        }

        _token = token_;

        emit TokenBound(token_);
    }

    /*//////////////////////////////////////////////////////////////
                                INTERNAL
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Reverts if `module` reads a token other than `token_`. A module that reads no token
     *      reports zero and passes.
     * @param module The module to check.
     * @param token_ The token the engine is, or is about to be, bound to.
     */
    function _requireSameToken(address module, address token_) private view {
        address moduleToken = IComplianceModule(module).token();
        if (moduleToken != address(0) && moduleToken != token_) {
            revert ModuleTokenMismatch(module, moduleToken, token_);
        }
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
