// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IComplianceModule} from "../../interfaces/IComplianceModule.sol";

/**
 * @title AbstractComplianceModule
 * @notice Shared plumbing for compliance rule modules: the engine binding and the hook gate.
 * @dev Holds no rule logic. Its only job is to guarantee that every module answers to exactly one
 *      compliance engine, and that lifecycle hooks cannot be called by anyone else. A module
 *      whose hooks are callable by arbitrary accounts has no integrity: an attacker could
 *      desynchronize its state from the token's and walk through the rule afterwards.
 *
 *      The binding is immutable and set at construction. Rebinding would let a second engine
 *      corrupt the state the first accumulated, and there is no use case for it in this design:
 *      a module is cheap to redeploy.
 */
abstract contract AbstractComplianceModule is IComplianceModule {
    /*//////////////////////////////////////////////////////////////
                                 STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @dev The compliance engine allowed to call the lifecycle hooks.
    address private immutable _compliance;

    /// @dev Whether the engine currently has this module registered.
    bool private _attached;

    /// @dev Whether the engine has ever registered this module. A stateful module that was removed
    ///      missed every movement made while it was out, so it can never be attached again.
    bool private _everAttached;

    /*//////////////////////////////////////////////////////////////
                                MODIFIERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Restricts a lifecycle hook to the bound engine.
     */
    modifier onlyCompliance() {
        if (msg.sender != _compliance) revert OnlyCompliance(msg.sender, _compliance);
        _;
    }

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Binds the module to its compliance engine.
     * @param compliance_ The engine that will call this module's hooks.
     */
    constructor(address compliance_) {
        if (compliance_ == address(0)) revert OnlyCompliance(address(0), address(0));
        _compliance = compliance_;
    }

    /*//////////////////////////////////////////////////////////////
                               ATTACHMENT
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IComplianceModule
    function bindCompliance(address compliance_) external onlyCompliance {
        _attached = true;
        _everAttached = true;

        emit ComplianceBound(compliance_);
    }

    /// @inheritdoc IComplianceModule
    function unbindCompliance(address compliance_) external onlyCompliance {
        _attached = false;

        emit ComplianceUnbound(compliance_);
    }

    /**
     * @inheritdoc IComplianceModule
     * @dev The base rule: only the engine this module was built for, and a module that is not
     *      plug and play only if it was never attached before. Modules that infer state from
     *      balances add a zero-supply requirement on top.
     */
    function canComplianceBind(address compliance_) public view virtual returns (bool) {
        if (compliance_ != _compliance) return false;
        return isPlugAndPlay() || !_everAttached;
    }

    /// @inheritdoc IComplianceModule
    function isPlugAndPlay() public pure virtual returns (bool);

    /*//////////////////////////////////////////////////////////////
                                  VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IComplianceModule
    function isComplianceBound(address compliance_) external view returns (bool) {
        return compliance_ == _compliance && _attached;
    }

    /// @inheritdoc IComplianceModule
    function compliance() external view returns (address) {
        return _compliance;
    }

    /*//////////////////////////////////////////////////////////////
                                INTERNAL
    //////////////////////////////////////////////////////////////*/

    /// @dev Whether the engine currently has this module registered.
    function _isAttached() internal view returns (bool) {
        return _attached;
    }
}
