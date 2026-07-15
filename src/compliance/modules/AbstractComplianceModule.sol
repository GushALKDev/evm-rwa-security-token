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
                                  VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IComplianceModule
    function compliance() external view returns (address) {
        return _compliance;
    }
}
