// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title ISecurityToken
 * @notice A permissioned security token: ERC-20 in shape, but every movement is gated by an
 *         identity check and a compliance check.
 * @dev Simplified subset of the ERC-3643 IERC3643 interface. The ERC-20 surface is preserved so
 *      existing tooling can read balances and build transfers, but the semantics differ: a
 *      transfer to an address that has not passed KYC reverts, and the issuer retains powers
 *      (freeze, forced recovery) that a plain ERC-20 has no concept of. Those powers exist
 *      because the token represents a regulated claim on a real asset, where the legal owner of
 *      record must be recoverable when keys are lost.
 */
interface ISecurityToken is IERC20 {
    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Emitted when an address is fully frozen or unfrozen.
     * @param investor The affected wallet.
     * @param frozen True if now frozen.
     */
    event AddressFrozen(address indexed investor, bool frozen);

    /**
     * @notice Emitted when part of a balance is frozen.
     * @param investor The affected wallet.
     * @param amount The newly frozen amount.
     */
    event TokensFrozen(address indexed investor, uint256 amount);

    /**
     * @notice Emitted when part of a balance is unfrozen.
     * @param investor The affected wallet.
     * @param amount The newly unfrozen amount.
     */
    event TokensUnfrozen(address indexed investor, uint256 amount);

    /**
     * @notice Emitted when a balance is force-moved from a lost wallet to a new one.
     * @param lostWallet The compromised or inaccessible wallet.
     * @param newWallet The replacement wallet.
     * @param amount The full balance moved.
     * @param frozenAmount The partially frozen amount carried over.
     * @param wasFullyFrozen Whether the full freeze flag was carried over.
     */
    event RecoverySuccess(
        address indexed lostWallet, address indexed newWallet, uint256 amount, uint256 frozenAmount, bool wasFullyFrozen
    );

    /**
     * @notice Emitted when the identity registry is replaced.
     * @param registry The new registry.
     */
    event IdentityRegistrySet(address indexed registry);

    /**
     * @notice Emitted when the compliance engine is replaced.
     * @param compliance The new engine.
     */
    event ComplianceSet(address indexed compliance);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Thrown when the zero address is supplied where a real account is required.
    error ZeroAddress();

    /// @notice Thrown when the recipient has not passed KYC, or their attestation has expired.
    error RecipientNotVerified(address to);

    /// @notice Thrown when the sender's wallet is fully frozen.
    error SenderAddressFrozen(address from);

    /// @notice Thrown when the recipient's wallet is fully frozen.
    error RecipientAddressFrozen(address to);

    /// @notice Thrown when a transfer would move tokens that are partially frozen.
    error InsufficientUnfrozenBalance(address from, uint256 available, uint256 required);

    /// @notice Thrown when the modular compliance rules reject the transfer.
    error ComplianceCheckFailed(address from, address to, uint256 amount);

    /// @notice Thrown when unfreezing more than is currently frozen.
    error UnfreezeAmountExceedsFrozen(address investor, uint256 frozen, uint256 requested);

    /// @notice Thrown when freezing more than the investor holds.
    error FreezeAmountExceedsBalance(address investor, uint256 balance, uint256 requested);

    /// @notice Thrown when recovering into a wallet that has not passed KYC.
    error NewWalletNotVerified(address newWallet);

    /// @notice Thrown when recovering from a wallet that holds nothing.
    error NothingToRecover(address lostWallet);

    /// @notice Thrown when recovering into the same wallet.
    error RecoveryToSameWallet(address wallet);

    /// @notice Thrown when the two wallets in a recovery belong to different investors.
    error RecoveryAcrossInvestors(bytes32 lostInvestorId, bytes32 newInvestorId);

    /*//////////////////////////////////////////////////////////////
                             ISSUANCE
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Issues new tokens to a verified investor.
     * @dev Restricted to the issuer (default admin). The recipient must be verified and the
     *      compliance rules must permit the issuance.
     * @param to The recipient.
     * @param amount The amount to mint.
     */
    function mint(address to, uint256 amount) external;

    /**
     * @notice Destroys tokens held by an investor.
     * @dev Restricted to the issuer (default admin). Burns unfrozen balance first; if the burn
     *      exceeds the unfrozen balance the frozen amount is reduced to cover it, since the
     *      issuer retiring a position outranks an operational freeze.
     * @param from The account to burn from.
     * @param amount The amount to burn.
     */
    function burn(address from, uint256 amount) external;

    /*//////////////////////////////////////////////////////////////
                              FREEZE CONTROLS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Freezes or unfreezes an entire wallet.
     * @dev Restricted to AGENT. A fully frozen wallet can neither send nor receive.
     * @param investor The wallet to freeze.
     * @param freeze True to freeze, false to unfreeze.
     */
    function setAddressFrozen(address investor, bool freeze) external;

    /**
     * @notice Freezes part of a wallet's balance.
     * @dev Restricted to AGENT. The frozen portion cannot move on a normal transfer, while the
     *      remainder stays liquid. Used for partial legal holds (a disputed lot, a pledge).
     * @param investor The wallet.
     * @param amount The amount to add to the frozen portion.
     */
    function freezePartialTokens(address investor, uint256 amount) external;

    /**
     * @notice Releases part of a wallet's frozen balance.
     * @dev Restricted to AGENT.
     * @param investor The wallet.
     * @param amount The amount to release.
     */
    function unfreezePartialTokens(address investor, uint256 amount) external;

    /**
     * @notice Halts all transfers.
     * @dev Restricted to AGENT. Mint and burn are also halted: pause is a market-wide stop.
     *      `forcedRecovery` is the one exception, since a pause is typically the response to the
     *      very incident recovery exists to resolve.
     */
    function pause() external;

    /**
     * @notice Resumes transfers.
     * @dev Restricted to AGENT.
     */
    function unpause() external;

    /*//////////////////////////////////////////////////////////////
                                RECOVERY
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Moves an investor's entire position from a lost wallet to a new verified wallet.
     * @dev Restricted to CUSTODIAN. This is the custody escape hatch: an investor whose keys are
     *      lost still legally owns the asset, and the register of ownership must be able to
     *      reflect that.
     *
     *      The move carries the full freeze state across (both the partially frozen amount and
     *      the full freeze flag), so recovery cannot be used to launder a freeze. The lost
     *      wallet ends at zero balance, zero frozen, and is removed from the identity registry
     *      so it can never receive tokens again. Total supply is unchanged.
     *
     *      Works while the token is paused. A key compromise is a common reason to halt trading,
     *      and stranding the affected position until the pause lifts would defeat the purpose.
     * @param lostWallet The compromised or inaccessible wallet.
     * @param newWallet The replacement wallet, which must already be verified.
     */
    function forcedRecovery(address lostWallet, address newWallet) external;

    /*//////////////////////////////////////////////////////////////
                                  VIEWS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Whether a transfer would be permitted right now.
     * @dev Superset of IModularCompliance.canTransfer: composes pause, recipient identity,
     *      freeze state and balance sufficiency with the modular rules. Lets a front end
     *      pre-validate without spending gas or guessing at the rule set. Shares one internal
     *      implementation with the transfer gate, so the answer cannot drift from what _update
     *      enforces.
     * @param from The sender.
     * @param to The recipient.
     * @param amount The transfer amount.
     * @return True if the transfer would succeed.
     */
    function canTransfer(address from, address to, uint256 amount) external view returns (bool);

    /**
     * @notice The amount of an investor's balance that is partially frozen.
     * @param investor The wallet.
     * @return The frozen amount.
     */
    function frozenTokens(address investor) external view returns (uint256);

    /**
     * @notice Whether a wallet is fully frozen.
     * @param investor The wallet.
     * @return True if fully frozen.
     */
    function isFrozen(address investor) external view returns (bool);

    /**
     * @notice The identity registry backing this token.
     * @return The registry address.
     */
    function identityRegistry() external view returns (address);

    /**
     * @notice The compliance engine backing this token.
     * @return The engine address.
     */
    function compliance() external view returns (address);
}
