// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

import {AbstractComplianceModule} from "./AbstractComplianceModule.sol";
import {IComplianceModule} from "../../interfaces/IComplianceModule.sol";
import {IIdentityRegistry} from "../../interfaces/IIdentityRegistry.sol";
import {Roles} from "../../Roles.sol";

/**
 * @title CountryRestrictionModule
 * @notice Blocks holders from disallowed jurisdictions.
 * @dev Stateless with respect to transfers: the rule reads the recipient's country from the
 *      identity registry and checks it against a blocklist. Nothing to track in the lifecycle
 *      hooks, so they are no-ops.
 *
 *      Blocklist rather than allowlist, deliberately. An allowlist would mean that adding a new
 *      permitted jurisdiction requires a governance action, and that an investor verified for an
 *      unlisted country silently cannot receive tokens. The identity registry is already the
 *      allowlist: if you are not in it, you hold nothing. This module answers a narrower
 *      question, which jurisdictions are sanctioned or otherwise excluded.
 */
contract CountryRestrictionModule is AbstractComplianceModule, AccessControl {
    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Emitted when a country is added to or removed from the blocklist.
     * @param country ISO 3166-1 numeric country code.
     * @param restricted True if now blocked.
     */
    event CountryRestrictionUpdated(uint16 indexed country, bool restricted);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Thrown when the zero address is supplied where a real account is required.
    error ZeroAddress();

    /*//////////////////////////////////////////////////////////////
                                 STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @dev The registry supplying each investor's country code.
    IIdentityRegistry private immutable _identityRegistry;

    /// @dev Blocked jurisdictions, by ISO 3166-1 numeric code.
    mapping(uint16 country => bool restricted) private _restricted;

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Deploys the module.
     * @param compliance_ The compliance engine that will call the hooks.
     * @param identityRegistry_ The registry supplying country codes.
     * @param issuer The account receiving DEFAULT_ADMIN_ROLE.
     * @param agent The account receiving AGENT_ROLE.
     */
    constructor(address compliance_, address identityRegistry_, address issuer, address agent)
        AbstractComplianceModule(compliance_)
    {
        if (identityRegistry_ == address(0) || issuer == address(0) || agent == address(0)) revert ZeroAddress();

        _identityRegistry = IIdentityRegistry(identityRegistry_);
        _grantRole(DEFAULT_ADMIN_ROLE, issuer);
        _grantRole(Roles.AGENT_ROLE, agent);
    }

    /*//////////////////////////////////////////////////////////////
                              RULE ADMIN
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Blocks or unblocks a jurisdiction.
     * @dev Restricted to AGENT: sanctions lists change on a compliance timescale, not a
     *      governance one.
     * @param country ISO 3166-1 numeric country code.
     * @param restricted True to block.
     */
    function setCountryRestricted(uint16 country, bool restricted) external onlyRole(Roles.AGENT_ROLE) {
        _restricted[country] = restricted;

        emit CountryRestrictionUpdated(country, restricted);
    }

    /*//////////////////////////////////////////////////////////////
                                  CHECK
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IComplianceModule
    function moduleCheck(address, address to, uint256) external view returns (bool) {
        // A burn has no recipient to place in a jurisdiction.
        if (to == address(0)) return true;

        return !_restricted[_identityRegistry.country(to)];
    }

    /*//////////////////////////////////////////////////////////////
                             LIFECYCLE HOOKS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IComplianceModule
    function moduleTransferred(address, address, uint256) external onlyCompliance {}

    /// @inheritdoc IComplianceModule
    function moduleCreated(address, uint256) external onlyCompliance {}

    /// @inheritdoc IComplianceModule
    function moduleDestroyed(address, uint256) external onlyCompliance {}

    /*//////////////////////////////////////////////////////////////
                                  VIEWS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Whether a jurisdiction is blocked.
     * @param country ISO 3166-1 numeric country code.
     * @return True if blocked.
     */
    function isRestricted(uint16 country) external view returns (bool) {
        return _restricted[country];
    }

    /**
     * @notice The identity registry supplying country codes.
     * @return The registry address.
     */
    function identityRegistry() external view returns (address) {
        return address(_identityRegistry);
    }

    /// @inheritdoc IComplianceModule
    function name() external pure returns (string memory) {
        return "CountryRestrictionModule";
    }
}
