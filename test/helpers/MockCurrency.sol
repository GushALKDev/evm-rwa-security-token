// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @notice Minimal 6-decimal ERC-20 standing in for the settlement currency in dividend tests.
 * @dev Six decimals on purpose: the real settlement currency for this instrument is a stablecoin
 *      like USDC, and a distributor tested only against an 18-decimal currency would hide
 *      precision bugs that appear when the dividend token is far coarser than the security token.
 */
contract MockCurrency is ERC20 {
    constructor() ERC20("Mock USD", "mUSD") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
