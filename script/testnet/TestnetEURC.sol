// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title TestnetEURC
 * @notice Testnet-only stand-in for EURC, the settlement currency the dividend distributor pays
 *         in. It has no value and must never be deployed on a network with real value.
 * @dev Six decimals, like Circle's EURC. Only the contract that deployed it can mint, and the
 *      demo deploys it from TestnetDesk, which mints exactly what each coupon payment deposits.
 *      Nothing else about Circle's token is modelled: no blocklist, no pause, no upgradeability.
 *
 *      Circle's own EURC exists on Base Sepolia, but Circle's faucet hands it out in small,
 *      rate-limited amounts, too little for coupons sized like a real note's.
 */
contract TestnetEURC is ERC20 {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Thrown when an account other than the minter tries to mint.
    error OnlyMinter(address caller);

    /*//////////////////////////////////////////////////////////////
                                 STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @dev The only account that can mint: the contract that deployed this token.
    address private immutable _minter;

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor() ERC20("Testnet Euro Coin", "EURC") {
        _minter = msg.sender;
    }

    /*//////////////////////////////////////////////////////////////
                                 MINTING
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Mints new tokens. Minter only.
     * @param to The recipient.
     * @param amount The amount, in base units (6 decimals).
     */
    function mint(address to, uint256 amount) external {
        if (msg.sender != _minter) revert OnlyMinter(msg.sender);
        _mint(to, amount);
    }

    /*//////////////////////////////////////////////////////////////
                                  VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ERC20
    function decimals() public pure override returns (uint8) {
        return 6;
    }

    /**
     * @notice The only account that can mint.
     * @return The minter address.
     */
    function minter() external view returns (address) {
        return _minter;
    }
}
