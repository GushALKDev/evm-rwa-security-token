// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @notice Minimal ERC-20 standing in for the SecurityToken in module unit tests.
 * @dev The modules read balances through the token and are called by an address they trust as the
 *      compliance engine. Testing them against a plain ERC-20 keeps each module's unit tests
 *      independent of the real token and the engine.
 *
 *      It also answers the few SecurityToken queries the modules make, each settable from the test:
 *      `recovering()` (read by the lockup and dividend hooks), `isFrozen()` and, through
 *      `identityRegistry()` pointing back at this contract, `isVerified()` (read by the dividend
 *      claim). Every wallet reads as verified and unfrozen unless a test says otherwise.
 */
contract MockToken is ERC20 {
    bool public recovering;

    mapping(address account => bool frozen) public isFrozen;
    mapping(address account => bool unverified) internal _unverified;

    constructor() ERC20("Mock", "MOCK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }

    function setRecovering(bool value) external {
        recovering = value;
    }

    function setFrozen(address account, bool value) external {
        isFrozen[account] = value;
    }

    function setVerified(address account, bool value) external {
        _unverified[account] = !value;
    }

    function identityRegistry() external view returns (address) {
        return address(this);
    }

    function isVerified(address account) external view returns (bool) {
        return !_unverified[account];
    }
}
