// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @notice Minimal ERC-20 standing in for the SecurityToken in module unit tests.
 * @dev The modules read balances through IERC20 and are called by an address they trust as the
 *      compliance engine. Testing them against a plain ERC-20 keeps each module's unit tests
 *      independent of the token and the engine, which do not exist yet.
 */
contract MockToken is ERC20 {
    constructor() ERC20("Mock", "MOCK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}
