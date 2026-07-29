// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IDividendDistributor
 * @notice Pro-rata distribution of income paid on the underlying note, in a settlement currency.
 * @dev The distributor is a compliance module, not a token extension. It is registered on the
 *      engine like any rule and earns its accounting from the lifecycle hooks the engine already
 *      fans out, so the token needs no knowledge of it and no new hook. Its moduleCheck always
 *      permits: it observes transfers, it does not judge them.
 *
 *      Income is distributed with the accumulator pattern, never by iterating holders. See the
 *      implementation for the invariant that makes the correction term exact.
 */
interface IDividendDistributor {
    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Emitted when the issuer deposits income for distribution.
     * @param from The depositor.
     * @param amount The amount of settlement currency deposited.
     * @param dividendsPerShare The accumulator value after the deposit.
     */
    event DividendsDeposited(address indexed from, uint256 amount, uint256 dividendsPerShare);

    /**
     * @notice Emitted when a holder withdraws their accrued dividends.
     * @param account The holder credited.
     * @param to The address paid.
     * @param amount The amount of settlement currency transferred.
     */
    event DividendsClaimed(address indexed account, address indexed to, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Thrown when the zero address is supplied where a real account is required.
    error ZeroAddress();

    /// @notice Thrown when depositing zero, which would move no funds and emit a misleading event.
    error ZeroDeposit();

    /// @notice Thrown when depositing while no tokens exist, since there is no one to distribute to.
    error NoSupply();

    /// @notice Thrown when a claim would pay nothing.
    error NothingToClaim(address account);

    /*//////////////////////////////////////////////////////////////
                               DISTRIBUTION
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Deposits income to be distributed pro-rata across current holders.
     * @param amount The amount of settlement currency to pull from the caller.
     */
    function deposit(uint256 amount) external;

    /**
     * @notice Withdraws the caller's accrued dividends.
     * @param to The address to pay.
     */
    function claim(address to) external;

    /*//////////////////////////////////////////////////////////////
                                  VIEWS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice The dividends an account can withdraw right now.
     * @param account The holder.
     * @return The claimable amount in settlement currency.
     */
    function claimable(address account) external view returns (uint256);

    /**
     * @notice The total dividends ever credited to an account, claimed or not.
     * @param account The holder.
     * @return The cumulative entitlement in settlement currency.
     */
    function accumulated(address account) external view returns (uint256);

    /**
     * @notice The settlement currency dividends are paid in.
     * @return The ERC-20 address.
     */
    function currency() external view returns (address);
}
