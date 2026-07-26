// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {ISecurityToken} from "./interfaces/ISecurityToken.sol";
import {IIdentityRegistry} from "./interfaces/IIdentityRegistry.sol";
import {IModularCompliance} from "./interfaces/IModularCompliance.sol";
import {Roles} from "./Roles.sol";

/**
 * @title SecurityToken
 * @notice A permissioned security token: ERC-20 in shape, but every movement is gated by an
 *         identity check and a compliance check, plus the issuer powers a regulated instrument
 *         requires (freeze, forced recovery).
 * @dev The whole point of this contract is the transfer gate. `_update` is the single chokepoint
 *      every mint, burn and transfer flows through in OZ v5, so the gate lives there and cannot be
 *      bypassed by any ERC-20 entrypoint (transfer, transferFrom, or a future one).
 *
 *      One internal `_checkTransfer` returns a status code; `canTransfer` compares it to Ok and
 *      `_update` translates a non-Ok code into the matching revert. The rule ordering therefore
 *      lives in exactly one place, so the view a front end reads can never drift from what a
 *      transfer actually enforces.
 *
 *      Ordering inside `_update` is deliberate: checks first, then `super._update` moves balances,
 *      then the compliance engine's lifecycle hook fires. The hooks run AFTER balances move
 *      because stateful modules (holder count, lockup clock) read post-transfer balances to decide
 *      what changed. This is CEI: the external calls to the engine come last, after state settles.
 */
contract SecurityToken is ISecurityToken, ERC20, AccessControl, Pausable, ReentrancyGuard {
    /*//////////////////////////////////////////////////////////////
                                  TYPES
    //////////////////////////////////////////////////////////////*/

    /// @dev The outcome of the shared transfer gate. Ok is the only passing value; every other
    ///      code maps one-to-one to a custom error in `_statusRevert`.
    enum TransferStatus {
        Ok,
        RecipientNotVerified,
        SenderFrozen,
        RecipientFrozen,
        InsufficientUnfrozen,
        ComplianceFailed
    }

    /*//////////////////////////////////////////////////////////////
                                 STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @dev The identity registry answering "may this address hold the token, and is that current?".
    IIdentityRegistry private _identityRegistry;

    /// @dev The modular compliance engine holding the pluggable rule set.
    IModularCompliance private _compliance;

    /// @dev Wallets that can neither send nor receive while the flag is set.
    mapping(address investor => bool frozen) private _frozen;

    /// @dev The portion of a wallet's balance that cannot move on a normal transfer.
    mapping(address investor => uint256 amount) private _frozenTokens;

    /// @dev Set only for the duration of a `forcedRecovery` call, to let its one internal transfer
    ///      through the pause. Never true across calls: `forcedRecovery` clears it before
    ///      returning, and nothing else can set it.
    bool private _recovering;

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Deploys the token.
     * @param name_ The token name.
     * @param symbol_ The token symbol.
     * @param issuer The account receiving DEFAULT_ADMIN_ROLE (mint, burn, role admin).
     * @param identityRegistry_ The identity registry backing the token.
     * @param compliance_ The compliance engine backing the token.
     */
    constructor(
        string memory name_,
        string memory symbol_,
        address issuer,
        address identityRegistry_,
        address compliance_
    ) ERC20(name_, symbol_) {
        if (issuer == address(0) || identityRegistry_ == address(0) || compliance_ == address(0)) revert ZeroAddress();

        _identityRegistry = IIdentityRegistry(identityRegistry_);
        _compliance = IModularCompliance(compliance_);
        _grantRole(DEFAULT_ADMIN_ROLE, issuer);

        emit IdentityRegistrySet(identityRegistry_);
        emit ComplianceSet(compliance_);
    }

    /*//////////////////////////////////////////////////////////////
                               ISSUANCE
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ISecurityToken
    function mint(address to, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _mint(to, amount);
    }

    /// @inheritdoc ISecurityToken
    function burn(address from, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        // Burn eats unfrozen balance first. If the burn is larger, the frozen portion is reduced
        // to cover the shortfall: the issuer retiring a position (a court order, a redemption)
        // outranks an operational freeze, so a freeze cannot shelter tokens from the issuer.
        uint256 frozen = _frozenTokens[from];
        uint256 free = balanceOf(from) - frozen;
        if (amount > free) {
            uint256 shortfall = amount - free;
            _frozenTokens[from] = frozen - shortfall;
            emit TokensUnfrozen(from, shortfall);
        }

        _burn(from, amount);
    }

    /*//////////////////////////////////////////////////////////////
                             FREEZE CONTROLS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ISecurityToken
    function setAddressFrozen(address investor, bool freeze) external onlyRole(Roles.AGENT_ROLE) {
        _frozen[investor] = freeze;

        emit AddressFrozen(investor, freeze);
    }

    /// @inheritdoc ISecurityToken
    function freezePartialTokens(address investor, uint256 amount) external onlyRole(Roles.AGENT_ROLE) {
        uint256 balance = balanceOf(investor);
        uint256 newFrozen = _frozenTokens[investor] + amount;
        // The frozen portion can never exceed the balance, or the unfrozen balance would underflow
        // in the transfer gate.
        if (newFrozen > balance) revert FreezeAmountExceedsBalance(investor, balance, newFrozen);

        _frozenTokens[investor] = newFrozen;

        emit TokensFrozen(investor, amount);
    }

    /// @inheritdoc ISecurityToken
    function unfreezePartialTokens(address investor, uint256 amount) external onlyRole(Roles.AGENT_ROLE) {
        uint256 frozen = _frozenTokens[investor];
        if (amount > frozen) revert UnfreezeAmountExceedsFrozen(investor, frozen, amount);

        _frozenTokens[investor] = frozen - amount;

        emit TokensUnfrozen(investor, amount);
    }

    /// @inheritdoc ISecurityToken
    function pause() external onlyRole(Roles.AGENT_ROLE) {
        _pause();
    }

    /// @inheritdoc ISecurityToken
    function unpause() external onlyRole(Roles.AGENT_ROLE) {
        _unpause();
    }

    /*//////////////////////////////////////////////////////////////
                                RECOVERY
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ISecurityToken
    function forcedRecovery(address lostWallet, address newWallet)
        external
        onlyRole(Roles.CUSTODIAN_ROLE)
        nonReentrant
    {
        if (lostWallet == newWallet) revert RecoveryToSameWallet(lostWallet);
        if (!_identityRegistry.isVerified(newWallet)) revert NewWalletNotVerified(newWallet);

        // Both wallets must belong to the same investor. Without this, a custodian could recover
        // into any verified wallet, handing a third party the balance and — via the freeze state
        // carried over below — freezing whatever that third party already held. Mirrors the
        // ERC-3643 check that the new wallet is a management key of the investor's ONCHAINID.
        bytes32 lostInvestorId = _identityRegistry.investorId(lostWallet);
        bytes32 newInvestorId = _identityRegistry.investorId(newWallet);
        if (lostInvestorId == bytes32(0) || lostInvestorId != newInvestorId) {
            revert RecoveryAcrossInvestors(lostInvestorId, newInvestorId);
        }

        uint256 amount = balanceOf(lostWallet);
        if (amount == 0) revert NothingToRecover(lostWallet);

        // Snapshot the freeze state before moving anything, so it can be carried over verbatim.
        uint256 frozenAmount = _frozenTokens[lostWallet];
        bool wasFullyFrozen = _frozen[lostWallet];

        // Retire the lost wallet: zero its frozen state and evict it from the registry so it can
        // never hold the token again. Done before the move so the recovery transfer sees a clean
        // sender, and so the partial-freeze gate cannot block the custodian's own move.
        delete _frozenTokens[lostWallet];
        delete _frozen[lostWallet];
        _identityRegistry.removeIdentity(lostWallet);

        // Move the full balance. The flag exempts this one move from both the pause and the
        // transfer gate, and is cleared immediately after, so nothing beyond this transfer passes.
        // The checks the gate would have run are either satisfied above (newWallet verified and
        // belonging to the same investor) or deliberately not applicable: a modular rule must not
        // be able to strand the position, and a freeze on either side is handled explicitly, the
        // sender's cleared just above and the destination's re-applied just below.
        _recovering = true;
        _transfer(lostWallet, newWallet, amount);
        _recovering = false;

        // Carry the freeze state onto the new wallet: recovery relocates a position, it does not
        // launder a hold. A frozen lot stays frozen at its new address.
        //
        // The two states carry over asymmetrically. A partial freeze is additive, so a pre-existing
        // balance on newWallet keeps its own frozen/unfrozen split. A full freeze is a property of
        // the investor, not of a lot, so it applies to the whole destination wallet — including
        // tokens already there. That is intended: the identity check above guarantees newWallet
        // belongs to the same investor, so a blocked subject stays blocked across all their wallets.
        if (frozenAmount != 0) {
            _frozenTokens[newWallet] += frozenAmount;
            emit TokensFrozen(newWallet, frozenAmount);
        }
        if (wasFullyFrozen) {
            _frozen[newWallet] = true;
            emit AddressFrozen(newWallet, true);
        }

        emit RecoverySuccess(lostWallet, newWallet, amount, frozenAmount, wasFullyFrozen);
    }

    /*//////////////////////////////////////////////////////////////
                             TRANSFER GATE
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev The single chokepoint for every balance change. OZ v5 routes mint, burn and transfer
     *      through `_update`, so gating here covers all three with no entrypoint left open.
     *
     *      Three branches by shape: mint (from == 0), burn (to == 0), transfer (both real). Each
     *      runs its gate, moves balances via `super._update`, then fires the matching engine hook
     *      AFTER the move so stateful modules read settled balances.
     *
     *      Forced recovery is exempt from both the pause and the transfer gate, which is why the
     *      pause check is written out rather than applied as a `whenNotPaused` modifier and why
     *      recovery gets its own branch. The reasoning is the same for both: a pause and a
     *      compliance rule are responses to ordinary trading, and recovery is the tool for
     *      resolving an incident, so neither may strand a compromised position on a wallet the
     *      investor no longer controls.
     *
     *      The exemption is narrow by construction. `_recovering` is set only inside
     *      `forcedRecovery`, which is CUSTODIAN-only, checks the destination itself, and clears
     *      the flag before returning.
     */
    function _update(address from, address to, uint256 amount) internal override {
        if (paused() && !_recovering) revert EnforcedPause();

        if (from == address(0)) {
            // Mint: recipient must clear the same gate a transfer recipient would.
            TransferStatus status = _checkTransfer(from, to, amount);
            if (status != TransferStatus.Ok) _statusRevert(status, from, to, amount);

            super._update(from, to, amount);
            _compliance.created(to, amount);
        } else if (to == address(0)) {
            // Burn: the issuer-facing `burn` has already reconciled the frozen portion, so the
            // gate here only needs the balance move itself. No recipient to verify.
            super._update(from, to, amount);
            _compliance.destroyed(from, amount);
        } else if (_recovering) {
            // Recovery: the gate is skipped entirely, not merely relaxed. Every check it performs
            // is either already guaranteed by forcedRecovery or is the wrong question to ask here.
            // The destination is verified and belongs to the same investor (checked there), the
            // sender's freeze state was cleared before the move, and the balance is exactly the
            // full amount. What remains are the modular rules, and those must not apply: a lockup
            // still running or a holder cap already met would strand a compromised position on a
            // wallet the investor no longer controls, which is the situation recovery exists to
            // resolve. A frozen destination is likewise no reason to block, since forcedRecovery
            // re-applies the freeze on the far side.
            //
            // The hook still fires: modules must observe the movement to keep their state correct,
            // even though their verdict on it is not consulted.
            super._update(from, to, amount);
            _compliance.transferred(from, to, amount);
        } else {
            // Transfer: the full gate.
            TransferStatus status = _checkTransfer(from, to, amount);
            if (status != TransferStatus.Ok) _statusRevert(status, from, to, amount);

            super._update(from, to, amount);
            _compliance.transferred(from, to, amount);
        }
    }

    /**
     * @dev The shared gate logic. Returns the first failing status, or Ok. Ordering is checked
     *      cheapest and most fundamental first: a frozen or unverified party is a harder stop than
     *      a modular rule. `canTransfer` and `_update` both call this, so they cannot disagree.
     *
     *      For a mint (from == 0) the sender-side checks are skipped: there is no sender to freeze
     *      and no balance to draw down.
     */
    function _checkTransfer(address from, address to, uint256 amount) internal view returns (TransferStatus) {
        if (!_identityRegistry.isVerified(to)) return TransferStatus.RecipientNotVerified;
        if (_frozen[to]) return TransferStatus.RecipientFrozen;

        if (from != address(0)) {
            if (_frozen[from]) return TransferStatus.SenderFrozen;
            // Only the unfrozen portion of a balance may move on a normal transfer.
            if (amount > balanceOf(from) - _frozenTokens[from]) return TransferStatus.InsufficientUnfrozen;
        }

        if (!_compliance.canTransfer(from, to, amount)) return TransferStatus.ComplianceFailed;

        return TransferStatus.Ok;
    }

    /**
     * @dev Translates a failing status code into its matching custom error. Split from
     *      `_checkTransfer` so the view path never reverts and the two paths share one source of
     *      rule ordering.
     */
    function _statusRevert(TransferStatus status, address from, address to, uint256 amount) private view {
        if (status == TransferStatus.RecipientNotVerified) revert RecipientNotVerified(to);
        if (status == TransferStatus.RecipientFrozen) revert RecipientAddressFrozen(to);
        if (status == TransferStatus.SenderFrozen) revert SenderAddressFrozen(from);
        if (status == TransferStatus.InsufficientUnfrozen) {
            revert InsufficientUnfrozenBalance(from, balanceOf(from) - _frozenTokens[from], amount);
        }
        // The only remaining non-Ok code.
        revert ComplianceCheckFailed(from, to, amount);
    }

    /*//////////////////////////////////////////////////////////////
                                  VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ISecurityToken
    function canTransfer(address from, address to, uint256 amount) external view returns (bool) {
        if (paused()) return false;
        return _checkTransfer(from, to, amount) == TransferStatus.Ok;
    }

    /// @inheritdoc ISecurityToken
    function frozenTokens(address investor) external view returns (uint256) {
        return _frozenTokens[investor];
    }

    /// @inheritdoc ISecurityToken
    function isFrozen(address investor) external view returns (bool) {
        return _frozen[investor];
    }

    /// @inheritdoc ISecurityToken
    function identityRegistry() external view returns (address) {
        return address(_identityRegistry);
    }

    /// @inheritdoc ISecurityToken
    function compliance() external view returns (address) {
        return address(_compliance);
    }
}
