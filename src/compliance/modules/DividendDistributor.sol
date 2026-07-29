// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {AbstractComplianceModule} from "./AbstractComplianceModule.sol";
import {IComplianceModule} from "../../interfaces/IComplianceModule.sol";
import {IDividendDistributor} from "../../interfaces/IDividendDistributor.sol";
import {ISecurityToken} from "../../interfaces/ISecurityToken.sol";
import {Roles} from "../../Roles.sol";

/**
 * @title DividendDistributor
 * @notice Distributes income paid on the note pro-rata across holders, in O(1) per operation.
 * @dev A real-estate note pays rent and interest, and every holder is owed a share proportional to
 *      what they held. The naive implementation walks the holder set on each payment, which is
 *      unbounded gas and fails at exactly the moment the issuance succeeds. This contract never
 *      enumerates holders.
 *
 *      # The accumulator
 *
 *      One global running total is kept: `_dividendsPerShare`, incremented on each deposit by
 *      `amount / totalSupply`. An account's lifetime entitlement is then
 *
 *          accumulated(a) = balanceOf(a) * _dividendsPerShare - _corrections[a]
 *
 *      where the correction absorbs everything the first term overstates or understates because
 *      the balance moved between deposits. The first term prices an account's CURRENT balance as
 *      if it had been held since inception; the correction is exactly the accumulated error in
 *      that pretence, so the difference is the true entitlement.
 *
 *      # Why the correction is exact
 *
 *      On any balance change of `amount` at accumulator value `p`, the invariant to preserve is
 *      that `accumulated` must not move: dividends accrue from holding over time, so acquiring or
 *      disposing of tokens is not itself an income event. A recipient's first term grows by
 *      `amount * p`, so its correction grows by the same, cancelling it. A sender's first term
 *      shrinks by `amount * p`, so its correction shrinks by the same. This is why a transfer
 *      cannot double-claim across the two parties: what the recipient's correction gains, the
 *      sender's loses, and the sum over all accounts of `accumulated` is unchanged by the move.
 *      Only a deposit ever raises it. Mint and burn are the one-sided cases of the same rule.
 *
 *      Corrections are therefore signed, and stored as `int256`. An account that acquires tokens
 *      late carries a positive correction (it must not be paid for deposits before it arrived);
 *      one that sold early carries a negative one (it keeps what it earned while holding).
 *
 *      # Precision
 *
 *      Integer division in `amount / totalSupply` would truncate most deposits to zero for any
 *      realistic supply, so the accumulator is scaled by `_MAGNITUDE` (2**128) and descaled on
 *      read. Two roundings remain, and they are handled differently:
 *
 *      - The deposit's own truncation is carried, not lost. Whatever the accumulator cannot yet
 *        represent is held in `_residue` and folded into the next deposit, so repeated deposits
 *        do not bleed value into an unclaimable balance.
 *      - Each holder's descaling in `accumulated` truncates down, at most one wei each. This is
 *        what keeps the contract solvent: the sum of claims is always at or below what was
 *        deposited, never above, so the last claimant is never left short.
 *
 *      `deposit` requires a non-zero supply rather than silently accruing to nobody.
 *
 *      # Integration
 *
 *      This is a compliance module. It is registered on the engine like a rule and gets its
 *      accounting from the lifecycle hooks the engine already fans out, so `SecurityToken` needs
 *      no dividend-specific hook and was not modified to support it. `moduleCheck` always returns
 *      true: the distributor observes transfers, it never blocks one. Withholding income is a
 *      matter for the freeze controls on the token, not for the transfer gate.
 *
 *      Forced recovery needs its own branch in the transfer hook. The hook fires on that path, but
 *      settling it like a sale would strand the unclaimed income on the compromised wallet, where
 *      whoever holds its keys could still withdraw it: the tokens would be rescued and the money
 *      left behind. The module therefore asks the token whether it is mid recovery and, if so,
 *      carries the entitlement across with the balance rather than splitting it between the two
 *      wallets. This is the one place the distributor depends on the token being a SecurityToken
 *      and not merely an ERC-20.
 */
contract DividendDistributor is AbstractComplianceModule, IDividendDistributor, AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    using SafeCast for int256;

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @dev Fixed-point scale for the accumulator. 2**128 keeps the descaled result exact for any
    ///      supply and deposit this instrument will see, while leaving 128 bits of headroom.
    uint256 private constant _MAGNITUDE = 2 ** 128;

    /*//////////////////////////////////////////////////////////////
                                 STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @dev The token whose balances define the pro-rata split. Typed as ISecurityToken rather
    ///      than IERC20 because the recovery branch in the transfer hook has to ask the token
    ///      whether the move it is being told about is a forced recovery.
    ISecurityToken private immutable _token;

    /// @dev The settlement currency dividends are paid in.
    IERC20 private immutable _currency;

    /// @dev Cumulative dividends per share, scaled by _MAGNITUDE.
    uint256 private _dividendsPerShare;

    /// @dev Per-account correction to the accumulator, scaled by _MAGNITUDE. Signed: see the
    ///      contract docs for why acquiring tokens raises it and disposing of them lowers it.
    mapping(address account => int256 correction) private _corrections;

    /// @dev Dividends already paid out per account, in settlement currency.
    mapping(address account => uint256 amount) private _withdrawn;

    /// @dev Undistributed remainder of past deposits, in SCALED units (always < totalSupply).
    ///      Folded into the next deposit so truncation is deferred rather than lost. Scaled, not
    ///      currency, because rounding it into whole currency units compounds into insolvency.
    uint256 private _residue;

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Deploys the module.
     * @param compliance_ The compliance engine that will call the hooks.
     * @param token_ The token whose balances define the pro-rata split.
     * @param currency_ The ERC-20 dividends are paid in.
     * @param issuer The account receiving DEFAULT_ADMIN_ROLE and AGENT_ROLE, which gates deposits.
     */
    constructor(address compliance_, address token_, address currency_, address issuer)
        AbstractComplianceModule(compliance_)
    {
        if (token_ == address(0) || currency_ == address(0) || issuer == address(0)) revert ZeroAddress();

        _token = ISecurityToken(token_);
        _currency = IERC20(currency_);
        _grantRole(DEFAULT_ADMIN_ROLE, issuer);
        _grantRole(Roles.AGENT_ROLE, issuer);
    }

    /*//////////////////////////////////////////////////////////////
                               DISTRIBUTION
    //////////////////////////////////////////////////////////////*/

    /**
     * @inheritdoc IDividendDistributor
     * @dev Restricted to AGENT: income comes from the issuer's collections on the underlying note,
     *      and an open deposit would let anyone perturb the accumulator. Reverts on zero supply
     *      rather than accepting funds no one can ever claim.
     */
    function deposit(uint256 amount) external onlyRole(Roles.AGENT_ROLE) nonReentrant {
        if (amount == 0) revert ZeroDeposit();

        uint256 supply = _token.totalSupply();
        if (supply == 0) revert NoSupply();

        // Effects before the external pull: the accumulator move is derived from `amount`, not
        // from a balance read, so a fee-on-transfer or rebasing currency would break conservation.
        // Such a currency is out of scope by construction (the settlement currency is fixed at
        // deployment and is a standard stablecoin), and the alternative of measuring the delta
        // would make the deposit path reentrant on the currency.
        //
        // The undistributed remainder of past deposits is folded in here rather than left behind,
        // so truncation is deferred instead of quietly accruing into an unclaimable balance.
        //
        // It is carried in SCALED units, and that detail is what keeps the carry sound. Carrying
        // it in currency units instead (deposit minus what the accumulator pays out) rounds the
        // dust UP each time and the error compounds: after a few deposits the sum of claims
        // exceeds the sum of deposits and the last claimant cannot be paid. Keeping the raw
        // modulus makes every deposit exact to within the single final truncation in
        // `accumulated`, so the shortfall stays at one wei per holder and never inverts.
        uint256 scaled = amount * _MAGNITUDE + _residue;

        _dividendsPerShare += scaled / supply;
        _residue = scaled % supply;

        emit DividendsDeposited(msg.sender, amount, _dividendsPerShare);

        _currency.safeTransferFrom(msg.sender, address(this), amount);
    }

    /**
     * @inheritdoc IDividendDistributor
     * @dev Pull, not push: the contract never iterates holders to pay them, and a holder that
     *      cannot receive the currency cannot block anyone else's claim. Guarded and CEI-ordered,
     *      so a malicious currency cannot reenter to claim twice.
     */
    function claim(address to) external nonReentrant {
        if (to == address(0)) revert ZeroAddress();

        uint256 amount = claimable(msg.sender);
        if (amount == 0) revert NothingToClaim(msg.sender);

        _withdrawn[msg.sender] += amount;

        emit DividendsClaimed(msg.sender, to, amount);

        _currency.safeTransfer(to, amount);
    }

    /*//////////////////////////////////////////////////////////////
                                  CHECK
    //////////////////////////////////////////////////////////////*/

    /**
     * @inheritdoc IComplianceModule
     * @dev Always permits. This module is an observer: it keeps accounts, it does not express a
     *      transfer restriction.
     */
    function moduleCheck(address, address, uint256) external pure returns (bool) {
        return true;
    }

    /*//////////////////////////////////////////////////////////////
                             LIFECYCLE HOOKS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IComplianceModule
    function moduleTransferred(address from, address to, uint256 amount) external onlyCompliance {
        // A self-transfer leaves the balance unchanged, so no correction is owed. It must be
        // discarded rather than allowed to net out: the two updates below would cancel exactly,
        // but only after transiting through an intermediate value, and skipping the write is both
        // cheaper and immune to the sign-handling trap that the same inference caused in
        // MaxHoldersModule.
        if (from == to) return;

        // A forced recovery is not a sale, and settling it like one would leave the unclaimed
        // income behind on a wallet the investor no longer controls, for whoever compromised it to
        // withdraw at leisure. Recovery relocates the position whole, so the accrued entitlement
        // moves with the balance: the correction and the withdrawal record are carried over, and
        // the lost wallet is left owed exactly nothing.
        if (_token.recovering()) {
            _corrections[to] += _corrections[from];
            _withdrawn[to] += _withdrawn[from];
            delete _corrections[from];
            delete _withdrawn[from];
            return;
        }

        // The sender keeps what accrued while holding; the recipient must not be paid for it.
        // Equal and opposite, so the sum of entitlements across all accounts is untouched.
        int256 delta = (amount * _dividendsPerShare).toInt256();
        _corrections[from] -= delta;
        _corrections[to] += delta;
    }

    /// @inheritdoc IComplianceModule
    function moduleCreated(address to, uint256 amount) external onlyCompliance {
        // A mint is a one-sided acquisition: the new tokens must not be paid for past deposits.
        _corrections[to] += (amount * _dividendsPerShare).toInt256();
    }

    /// @inheritdoc IComplianceModule
    function moduleDestroyed(address from, uint256 amount) external onlyCompliance {
        // A burn is a one-sided disposal. The correction falls with the balance, so dividends
        // already accrued to the burned tokens remain claimable by the account that held them.
        _corrections[from] -= (amount * _dividendsPerShare).toInt256();
    }

    /*//////////////////////////////////////////////////////////////
                                  VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IDividendDistributor
    function claimable(address account) public view returns (uint256) {
        return accumulated(account) - _withdrawn[account];
    }

    /// @inheritdoc IDividendDistributor
    function accumulated(address account) public view returns (uint256) {
        // toUint256 reverts on a negative value rather than wrapping it into a huge claim. The
        // difference is non-negative whenever the corrections are maintained correctly, so this
        // cast is a last-resort assertion on that invariant, not an expected code path.
        int256 gross = (_token.balanceOf(account) * _dividendsPerShare).toInt256() - _corrections[account];
        return gross.toUint256() / _MAGNITUDE;
    }

    /// @inheritdoc IDividendDistributor
    function currency() external view returns (address) {
        return address(_currency);
    }

    /**
     * @notice The dividends already withdrawn by an account.
     * @param account The holder.
     * @return The amount withdrawn in settlement currency.
     */
    function withdrawn(address account) external view returns (uint256) {
        return _withdrawn[account];
    }

    /**
     * @notice The cumulative dividends per share, scaled by the internal magnitude.
     * @return The scaled accumulator.
     */
    function dividendsPerShare() external view returns (uint256) {
        return _dividendsPerShare;
    }

    /**
     * @notice The undistributed remainder carried into the next deposit, in scaled units.
     * @dev Scaled by the internal magnitude, not a settlement-currency amount. Exposed for
     *      accounting and tests; it is always strictly less than the token's total supply.
     * @return The scaled residue.
     */
    function residue() external view returns (uint256) {
        return _residue;
    }

    /**
     * @notice The token whose balances define the pro-rata split.
     * @return The token address.
     */
    function token() external view returns (address) {
        return address(_token);
    }

    /// @inheritdoc IComplianceModule
    function name() external pure returns (string memory) {
        return "DividendDistributor";
    }
}
