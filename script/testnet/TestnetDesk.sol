// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IComplianceModule} from "../../src/interfaces/IComplianceModule.sol";
import {IDividendDistributor} from "../../src/interfaces/IDividendDistributor.sol";
import {IIdentityRegistry} from "../../src/interfaces/IIdentityRegistry.sol";
import {ISecurityToken} from "../../src/interfaces/ISecurityToken.sol";
import {TestnetEURC} from "./TestnetEURC.sol";

/**
 * @title TestnetDesk
 * @notice Testnet-only stand-in for the three off-chain parties an investor deals with: the KYC
 *         provider, the issuer's primary issuance and the paying agent. It lets a stranger's wallet
 *         hold and trade the token on a public demo. Never deploy it on a network with real value.
 * @dev The protocol keeps every one of these powers behind a role, so the desk holds the roles and
 *      exposes each one through a single function:
 *
 *      - `onboard` (AGENT on the identity registry) registers the caller, never another address.
 *        It checks only that the country code is between 1 and 999, the range of ISO 3166-1
 *        numeric codes, not that the code is assigned. It does not check who the caller is, where
 *        they live or whether they are accredited: the caller declares a country, the record is
 *        marked not accredited (no module reads that flag), and the attestation expires after
 *        KYC_VALIDITY. Calling it again changes the country and renews the expiry. Like any agent
 *        write it replaces the whole record, so it also undoes an agent's removal of the caller and
 *        resets a custom investor id to the default one.
 *      - `claimTokens` (DEFAULT_ADMIN_ROLE on the token, the only role that can mint) mints
 *        TOKENS_PER_CLAIM to the caller at most once per CLAIM_COOLDOWN. The mint runs the token's
 *        full gate, so an unverified, frozen or restricted-country caller, or a register already
 *        at its holder cap, makes it revert. Nothing is paid for the tokens: there is no sale.
 *      - `payCoupon` (AGENT on the distributor, which gates deposits) mints COUPON_PER_TOKEN EURC
 *        for every token outstanding and deposits it for every holder, as any coupon does, at most
 *        once per COUPON_INTERVAL whoever calls it. It does not model collections on the property,
 *        a payment schedule or maturity.
 *
 *      The only other functions are the owner's: `setDistributor`, which wires the distributor once
 *      and checks its currency and token, and Ownable's ownership transfer and renouncement. None of
 *      them uses the desk's roles, so the roles cannot be exercised in any other way.
 *
 *      What a stranger can still do on a shared deployment, and why it does not brick the demo:
 *      the per-address cooldown does not stop one person using many addresses, so the holder cap
 *      can be filled at two transactions per address (onboard, then claimTokens). The cap is the
 *      protocol's own rule, kept at the value Deploy.s.sol sets; the agent reopens a full register
 *      with `MaxHoldersModule.setMaxHolders`. Paying coupons early or often only pays holders.
 */
contract TestnetDesk is Ownable {
    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Emitted when the desk mints tokens to a caller.
     * @param account The caller, who receives the tokens.
     * @param amount The amount minted.
     */
    event TokensClaimed(address indexed account, uint256 amount);

    /**
     * @notice Emitted when a coupon is deposited into the distributor.
     * @param caller The account that triggered the payment.
     * @param amount The EURC deposited.
     */
    event CouponPaid(address indexed caller, uint256 amount);

    /**
     * @notice Emitted when the owner wires the distributor.
     * @param distributor The distributor coupons are deposited into.
     */
    event DistributorSet(address indexed distributor);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Thrown when the zero address is supplied where a real account is required.
    error ZeroAddress();

    /// @notice Thrown when a country code is outside 1 to 999, the range of ISO 3166-1 numeric codes.
    error InvalidCountry(uint16 country);

    /// @notice Thrown when an address claims tokens again before its cooldown has passed.
    error ClaimTooSoon(address account, uint256 nextClaimAt);

    /// @notice Thrown when a coupon is paid again before the interval has passed.
    error CouponTooSoon(uint256 nextCouponAt);

    /// @notice Thrown when a coupon is paid before the owner has wired the distributor.
    error DistributorNotSet();

    /// @notice Thrown when the owner tries to wire a second distributor.
    error DistributorAlreadySet(address distributor);

    /// @notice Thrown when a distributor pays in another currency or splits another token.
    error DistributorMismatch(address distributor);

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice How long an attestation written by `onboard` stays valid.
    uint64 public constant KYC_VALIDITY = 30 days;

    /// @notice Tokens minted per claim: ten tokens, 18 decimals.
    uint256 public constant TOKENS_PER_CLAIM = 10e18;

    /// @notice Minimum time between two claims from the same address.
    uint256 public constant CLAIM_COOLDOWN = 1 days;

    /// @notice Minimum time between two coupon payments, whoever triggers them.
    uint256 public constant COUPON_INTERVAL = 10 minutes;

    /// @notice EURC paid per whole token outstanding on each coupon: 5 EURC, 6 decimals.
    uint256 public constant COUPON_PER_TOKEN = 5e6;

    /// @dev One whole token in base units.
    uint256 private constant _ONE_TOKEN = 1e18;

    /*//////////////////////////////////////////////////////////////
                                 STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @dev The registry `onboard` writes to.
    IIdentityRegistry private immutable _identityRegistry;

    /// @dev The token `claimTokens` mints and whose supply sizes each coupon.
    ISecurityToken private immutable _token;

    /// @dev The settlement currency, deployed by this desk so that only the desk can mint it.
    TestnetEURC private immutable _currency;

    /// @dev The distributor coupons are deposited into, and when the last one was paid. Packed:
    ///      `payCoupon` reads both and writes the timestamp.
    IDividendDistributor private _distributor; // 20 bytes -┐  Slot 1 (28/32)
    uint64 private _lastCouponAt; //               8 bytes -┘

    /// @dev Timestamp of each address's last token claim.
    mapping(address account => uint256 timestamp) private _lastClaim;

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Deploys the desk and its settlement currency.
     * @dev The distributor takes the currency in its constructor, so it is deployed after the desk
     *      and wired with `setDistributor`.
     * @param owner_ The account allowed to wire the distributor.
     * @param identityRegistry_ The registry `onboard` writes to.
     * @param token_ The token `claimTokens` mints.
     */
    constructor(address owner_, address identityRegistry_, address token_) Ownable(owner_) {
        if (identityRegistry_ == address(0) || token_ == address(0)) revert ZeroAddress();

        _identityRegistry = IIdentityRegistry(identityRegistry_);
        _token = ISecurityToken(token_);
        _currency = new TestnetEURC();
    }

    /*//////////////////////////////////////////////////////////////
                                 WIRING
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Wires the distributor coupons are deposited into. Owner only, once.
     * @param distributor_ A distributor that pays in this desk's currency and splits this desk's token.
     */
    function setDistributor(address distributor_) external onlyOwner {
        address current = address(_distributor);
        if (current != address(0)) revert DistributorAlreadySet(current);
        // A distributor paying in another currency would pull a balance the desk never minted; one
        // splitting another token would pay a register this desk does not issue.
        if (
            IDividendDistributor(distributor_).currency() != address(_currency)
                || IComplianceModule(distributor_).token() != address(_token)
        ) revert DistributorMismatch(distributor_);

        _distributor = IDividendDistributor(distributor_);

        emit DistributorSet(distributor_);
    }

    /*//////////////////////////////////////////////////////////////
                              KYC STAND-IN
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Registers the caller as a verified investor resident in `country`.
     * @dev Checks nothing about the caller and only the range of the code (see the contract notes).
     *      Writes through the registry's agent path, which supersedes any attestation issued for the
     *      caller before.
     * @param country ISO 3166-1 numeric country code, 1 to 999.
     */
    function onboard(uint16 country) external {
        if (country == 0 || country > 999) revert InvalidCountry(country);

        _identityRegistry.registerIdentity(msg.sender, country, false, uint64(block.timestamp) + KYC_VALIDITY);
    }

    /*//////////////////////////////////////////////////////////////
                            ISSUANCE STAND-IN
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Mints TOKENS_PER_CLAIM to the caller, at most once per CLAIM_COOLDOWN.
     * @dev The cooldown is recorded before the mint, and a mint the gate rejects reverts the whole
     *      call, so a rejected claim does not use up the day.
     */
    function claimTokens() external {
        uint256 next = nextClaimAt(msg.sender);
        if (block.timestamp < next) revert ClaimTooSoon(msg.sender, next);

        _lastClaim[msg.sender] = block.timestamp;

        emit TokensClaimed(msg.sender, TOKENS_PER_CLAIM);

        _token.mint(msg.sender, TOKENS_PER_CLAIM);
    }

    /*//////////////////////////////////////////////////////////////
                          PAYING AGENT STAND-IN
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Deposits a coupon of COUPON_PER_TOKEN per token outstanding, at most once per
     *         COUPON_INTERVAL. Anyone can trigger it.
     * @dev The EURC is minted here and pulled by the distributor in the same call. The distributor
     *      reverts on a zero amount or a zero supply rather than accepting funds nobody can claim.
     */
    function payCoupon() external {
        IDividendDistributor target = _distributor;
        if (address(target) == address(0)) revert DistributorNotSet();
        uint256 next = nextCouponAt();
        if (block.timestamp < next) revert CouponTooSoon(next);

        uint256 amount = couponAmount();
        _lastCouponAt = uint64(block.timestamp);

        emit CouponPaid(msg.sender, amount);

        _currency.mint(address(this), amount);
        _currency.approve(address(target), amount);
        target.deposit(amount);
    }

    /*//////////////////////////////////////////////////////////////
                                  VIEWS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Earliest timestamp at which an address can claim tokens again.
     * @param account The address.
     * @return The timestamp, zero if it never claimed.
     */
    function nextClaimAt(address account) public view returns (uint256) {
        uint256 last = _lastClaim[account];
        return last == 0 ? 0 : last + CLAIM_COOLDOWN;
    }

    /**
     * @notice Earliest timestamp at which the next coupon can be paid.
     * @return The timestamp, zero if no coupon was ever paid.
     */
    function nextCouponAt() public view returns (uint256) {
        uint256 last = _lastCouponAt;
        return last == 0 ? 0 : last + COUPON_INTERVAL;
    }

    /**
     * @notice The EURC the next coupon would deposit at the current supply, rounded down.
     * @return The amount, 6 decimals.
     */
    function couponAmount() public view returns (uint256) {
        return _token.totalSupply() * COUPON_PER_TOKEN / _ONE_TOKEN;
    }

    /**
     * @notice Timestamp of the last coupon payment.
     * @return The timestamp, zero if none was paid.
     */
    function lastCouponAt() external view returns (uint256) {
        return _lastCouponAt;
    }

    /**
     * @notice Timestamp of an address's last token claim.
     * @param account The address.
     * @return The timestamp, zero if it never claimed.
     */
    function lastClaim(address account) external view returns (uint256) {
        return _lastClaim[account];
    }

    /**
     * @notice The settlement currency this desk mints for coupons.
     * @return The currency address.
     */
    function currency() external view returns (address) {
        return address(_currency);
    }

    /**
     * @notice The distributor coupons are deposited into.
     * @return The distributor address, zero until wired.
     */
    function distributor() external view returns (address) {
        return address(_distributor);
    }

    /**
     * @notice The token this desk mints.
     * @return The token address.
     */
    function token() external view returns (address) {
        return address(_token);
    }

    /**
     * @notice The registry this desk writes to.
     * @return The registry address.
     */
    function identityRegistry() external view returns (address) {
        return address(_identityRegistry);
    }
}
