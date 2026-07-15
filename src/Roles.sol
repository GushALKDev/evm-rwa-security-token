// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title Roles
 * @notice Shared role identifiers for the permissioned security token system.
 * @dev Defined once in a library so every layer (token, registry, compliance) derives the same
 *      constants. Redefining a role hash per contract is a silent authorization bug: a grant on
 *      one contract would not match the check on another.
 *
 *      The default admin role (0x00, from OpenZeppelin AccessControl) is held by the ISSUER and
 *      administers every other role.
 */
library Roles {
    /**
     * @notice The compliance officer role.
     * @dev Manages the identity registry (register, update, remove investors) and the freeze
     *      controls on the token. This is the operational role exercised day to day by the
     *      regulated entity's compliance desk.
     */
    bytes32 internal constant AGENT_ROLE = keccak256("AGENT_ROLE");

    /**
     * @notice The custodian role.
     * @dev Authorized to perform forced recovery, moving a full balance from a lost or
     *      compromised wallet to a new verified wallet. Deliberately separated from AGENT so
     *      that day to day compliance operations cannot seize investor balances.
     */
    bytes32 internal constant CUSTODIAN_ROLE = keccak256("CUSTODIAN_ROLE");
}
