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
    address public token;

    constructor(address compliance_, string memory name_) AbstractComplianceModule(compliance_) {
        _name = name_;
    }

    function setToken(address token_) external {
        token = token_;
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

    function isPlugAndPlay() public pure virtual override returns (bool) {
        return true;
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

    function token() external pure returns (address) {
        return address(0);
    }

    function isPlugAndPlay() public pure override returns (bool) {
        return true;
    }
}

/// @notice A stateful stand-in: not plug and play, so the engine can attach it only once.
contract StatefulMockModule is MockModule {
    constructor(address compliance_) MockModule(compliance_, "StatefulMockModule") {}

    function isPlugAndPlay() public pure override returns (bool) {
        return false;
    }
}

/**
 * @notice A module that reenters an arbitrary target from inside the transfer hook.
 * @dev Stands in for a malicious or buggy module the issuer registered. Once armed, the first
 *      transfer hook makes one call, records that it tried and how the call ended, and returns
 *      normally, so the outer operation's own result stays visible to the test.
 */
contract ReenteringModule is AbstractComplianceModule {
    address public target;
    bytes public reentryCall;
    bool public reentryAttempted;
    bool public reentrySucceeded;
    bytes public reentryError;

    constructor(address compliance_) AbstractComplianceModule(compliance_) {}

    function arm(address target_, bytes calldata call_) external {
        target = target_;
        reentryCall = call_;
    }

    function moduleCheck(address, address, uint256) external pure returns (bool) {
        return true;
    }

    function moduleTransferred(address, address, uint256) external onlyCompliance {
        if (target == address(0) || reentryAttempted) return;
        reentryAttempted = true;
        (bool ok, bytes memory ret) = target.call(reentryCall);
        reentrySucceeded = ok;
        if (!ok) reentryError = ret;
    }

    function moduleCreated(address, uint256) external onlyCompliance {}

    function moduleDestroyed(address, uint256) external onlyCompliance {}

    function token() external pure returns (address) {
        return address(0);
    }

    function name() external pure returns (string memory) {
        return "ReenteringModule";
    }

    function isPlugAndPlay() public pure override returns (bool) {
        return true;
    }
}
