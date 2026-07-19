// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AbstractComplianceModule} from "../../src/compliance/modules/AbstractComplianceModule.sol";
import {IComplianceModule} from "../../src/interfaces/IComplianceModule.sol";

/**
 * @notice Minimal module standing in for a real rule in ModularCompliance unit tests.
 * @dev Reuses AbstractComplianceModule so the onlyCompliance gate is the production one: the
 *      engine can only drive this module if it is the bound compliance address. The check result
 *      is toggleable and every hook is counted, so tests can assert the engine short-circuits the
 *      check and fans each lifecycle event to every module.
 */
contract MockModule is AbstractComplianceModule {
    string private _name;
    bool public allow = true;

    uint256 public transferredCount;
    uint256 public createdCount;
    uint256 public destroyedCount;

    address public lastFrom;
    address public lastTo;
    uint256 public lastAmount;

    constructor(address compliance_, string memory name_) AbstractComplianceModule(compliance_) {
        _name = name_;
    }

    function setAllow(bool allow_) external {
        allow = allow_;
    }

    function moduleCheck(address, address, uint256) external view returns (bool) {
        return allow;
    }

    function moduleTransferred(address from, address to, uint256 amount) external onlyCompliance {
        ++transferredCount;
        lastFrom = from;
        lastTo = to;
        lastAmount = amount;
    }

    function moduleCreated(address to, uint256 amount) external onlyCompliance {
        ++createdCount;
        lastTo = to;
        lastAmount = amount;
    }

    function moduleDestroyed(address from, uint256 amount) external onlyCompliance {
        ++destroyedCount;
        lastFrom = from;
        lastAmount = amount;
    }

    function name() external view returns (string memory) {
        return _name;
    }
}

/// @notice A module bound to a different engine, to exercise the ModuleNotBound guard in addModule.
contract WrongEngineModule is AbstractComplianceModule {
    constructor(address compliance_) AbstractComplianceModule(compliance_) {}

    function moduleCheck(address, address, uint256) external pure returns (bool) {
        return true;
    }

    function moduleTransferred(address, address, uint256) external onlyCompliance {}
    function moduleCreated(address, uint256) external onlyCompliance {}
    function moduleDestroyed(address, uint256) external onlyCompliance {}

    function name() external pure returns (string memory) {
        return "WrongEngineModule";
    }
}
