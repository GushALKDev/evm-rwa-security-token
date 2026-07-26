// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {SecurityToken} from "../src/SecurityToken.sol";
import {IdentityRegistry} from "../src/identity/IdentityRegistry.sol";
import {ModularCompliance} from "../src/compliance/ModularCompliance.sol";
import {MaxHoldersModule} from "../src/compliance/modules/MaxHoldersModule.sol";
import {CountryRestrictionModule} from "../src/compliance/modules/CountryRestrictionModule.sol";
import {LockupModule} from "../src/compliance/modules/LockupModule.sol";
import {DocumentRegistry} from "../src/DocumentRegistry.sol";
import {IDocumentRegistry} from "../src/interfaces/IDocumentRegistry.sol";
import {Roles} from "../src/Roles.sol";

/**
 * @title Deploy
 * @notice Deploys the full security token system, wires it together, and anchors the terms
 *         document by a hash computed from the file on disk.
 * @dev The deployment order is forced by the constructor dependencies, not chosen:
 *
 *      1. `ModularCompliance` first, because every module binds to an engine address that is
 *         immutable at construction.
 *      2. `IdentityRegistry` next, because the token and the country module both read it.
 *      3. `SecurityToken` third. It takes the engine and registry addresses in its constructor,
 *         so both must already exist.
 *      4. The modules last. `MaxHoldersModule` and `LockupModule` hold the token address as
 *         `immutable`, so they cannot be built before the token exists. This is why modules come
 *         after the token rather than before it: the token needs the engine, the stateful modules
 *         need the token, and only the engine sits below both.
 *
 *      The wiring calls that close the graph (`addModule`, `bindToken`, and granting the token
 *      AGENT on the registry) then run once every address is known.
 *
 *      Anchoring reads `docs/RealEstateNote-Terms.md` through `vm.readFile` and hashes the bytes
 *      here rather than accepting a hash as a parameter. A hardcoded hash would drift silently the
 *      first time the document is edited, which is the exact failure the anchor exists to detect.
 */
contract Deploy is Script {
    /*//////////////////////////////////////////////////////////////
                              CONFIGURATION
    //////////////////////////////////////////////////////////////*/

    /// @dev Path of the legal instrument the token represents, hashed and anchored at deployment.
    string internal constant TERMS_PATH = "docs/RealEstateNote-Terms.md";

    /// @dev Where the terms document is published. The anchor proves which version is in force;
    ///      the URI only says where to fetch it.
    ///
    ///      A branch URL, not a commit permalink. This constant is only read once, at deployment,
    ///      to set the initial anchor. Amending the terms afterwards goes through `setDocument` on
    ///      the deployed registry, which rewrites both the URI and the hash, so this line is never
    ///      part of that flow. A permalink would therefore stay frozen on the version that existed
    ///      at deployment, and every later amendment would publish a stale location.
    string internal constant TERMS_URI =
        "https://raw.githubusercontent.com/GushALKDev/evm-rwa-security-token/main/docs/RealEstateNote-Terms.md";

    /// @dev Document name as a readable label rather than a hash, so it decodes off-chain.
    bytes32 internal constant TERMS_NAME = bytes32("TERMS");

    string internal constant TOKEN_NAME = "Real Estate Note Token";
    string internal constant TOKEN_SYMBOL = "RENT";

    /// @dev Holder cap. A Reg D style private placement is capped well below a public offering.
    uint256 internal constant MAX_HOLDERS = 499;

    /// @dev Holding period before an acquired position may move.
    uint64 internal constant LOCKUP_PERIOD = 365 days;

    /*//////////////////////////////////////////////////////////////
                                 TYPES
    //////////////////////////////////////////////////////////////*/

    /// @dev The deployed system, returned so tests can drive the same wiring the script performs.
    struct Deployment {
        ModularCompliance compliance;
        IdentityRegistry identityRegistry;
        SecurityToken token;
        MaxHoldersModule maxHolders;
        CountryRestrictionModule countryRestriction;
        LockupModule lockup;
        DocumentRegistry documentRegistry;
        bytes32 termsHash;
    }

    /*//////////////////////////////////////////////////////////////
                                 SCRIPT
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Deploys and wires the system, reading the operator addresses from the environment.
     * @dev ISSUER, AGENT and CUSTODIAN default to the broadcasting account when unset, which is
     *      what a local Anvil run wants. A real deployment sets three distinct accounts: the whole
     *      point of separating AGENT from CUSTODIAN is that a compliance desk cannot seize
     *      balances, and collapsing them into one key discards that separation.
     * @return The deployed system.
     */
    function run() external returns (Deployment memory) {
        address deployer = msg.sender;
        address issuer = vm.envOr("ISSUER", deployer);
        address agent = vm.envOr("AGENT", deployer);
        address custodian = vm.envOr("CUSTODIAN", deployer);

        vm.startBroadcast();
        Deployment memory d = _deploy(issuer, agent, custodian);
        vm.stopBroadcast();

        _logDeployment(d, issuer, agent, custodian);

        return d;
    }

    /**
     * @notice Deploys every contract, wires the graph, and anchors the terms document.
     * @dev Separated from `run` so tests can call it directly without a broadcast context. The
     *      caller must hold the roles being exercised here: the wiring calls are admin-gated, and
     *      this function runs them as whoever is executing it.
     *
     *      This means `issuer` must be the executing account for the wiring to succeed. When
     *      deploying on behalf of a different issuer, the DEFAULT_ADMIN_ROLE grants still land on
     *      that issuer, but the wiring calls would revert, so the deployer keeps admin here and
     *      the handover is a separate operational step.
     * @param issuer The account receiving DEFAULT_ADMIN_ROLE on every contract.
     * @param agent The account receiving AGENT_ROLE on the registry and the rule modules.
     * @param custodian The account receiving CUSTODIAN_ROLE on the token.
     * @return d The deployed system.
     */
    function _deploy(address issuer, address agent, address custodian) internal returns (Deployment memory d) {
        // 1. The engine. Modules bind to it immutably, so nothing that binds can precede it.
        d.compliance = new ModularCompliance(issuer);

        // 2. The registry. Both the token and the country module read from it.
        d.identityRegistry = new IdentityRegistry(issuer, agent);

        // 3. The token. Takes the engine and registry, both of which now exist.
        d.token =
            new SecurityToken(TOKEN_NAME, TOKEN_SYMBOL, issuer, address(d.identityRegistry), address(d.compliance));

        // 4. The modules. The stateful two hold the token address as immutable, so they come last.
        d.maxHolders = new MaxHoldersModule(address(d.compliance), address(d.token), issuer, agent, MAX_HOLDERS);
        d.countryRestriction =
            new CountryRestrictionModule(address(d.compliance), address(d.identityRegistry), issuer, agent);
        d.lockup = new LockupModule(address(d.compliance), address(d.token), issuer, agent, LOCKUP_PERIOD);

        // 5. Close the graph. addModule rejects a module not already pointing at this engine, so
        //    these calls also assert that step 4 bound the right engine.
        d.compliance.addModule(address(d.maxHolders));
        d.compliance.addModule(address(d.countryRestriction));
        d.compliance.addModule(address(d.lockup));

        // bindToken is one-shot: the engine only ever accepts hooks from this token.
        d.compliance.bindToken(address(d.token));

        // The token calls removeIdentity on the registry during forced recovery, which is
        // AGENT-gated. Without this grant, recovery reverts at the last step.
        d.identityRegistry.grantRole(Roles.AGENT_ROLE, address(d.token));

        // The custodian is the only account that may move a balance out of a lost wallet.
        d.token.grantRole(Roles.CUSTODIAN_ROLE, custodian);

        // The agent operates the freeze controls and the pause on the token.
        d.token.grantRole(Roles.AGENT_ROLE, agent);

        // 6. Anchor the terms by a hash of the bytes on disk, never a hardcoded constant.
        d.documentRegistry = new DocumentRegistry(issuer);
        d.termsHash = keccak256(bytes(vm.readFile(TERMS_PATH)));
        d.documentRegistry.setDocument(TERMS_NAME, TERMS_URI, d.termsHash);

        _verify(d, issuer, agent, custodian);
    }

    /*//////////////////////////////////////////////////////////////
                             SANITY CHECKS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Asserts the deployment is actually usable before the script reports success. Each check
     *      corresponds to a wiring step that fails silently rather than loudly if skipped: a
     *      missing role or an unbound engine does not revert at deployment, it reverts on the
     *      first transfer in production.
     */
    function _verify(Deployment memory d, address issuer, address agent, address custodian) internal view {
        // The token points at the engine and registry it was built with.
        require(d.token.compliance() == address(d.compliance), "token: wrong compliance");
        require(d.token.identityRegistry() == address(d.identityRegistry), "token: wrong registry");

        // The engine accepts hooks only from this token, and holds all three modules.
        require(d.compliance.token() == address(d.token), "compliance: token not bound");
        require(d.compliance.modules().length == 3, "compliance: module count");
        require(d.compliance.isModuleRegistered(address(d.maxHolders)), "compliance: maxHolders missing");
        require(d.compliance.isModuleRegistered(address(d.countryRestriction)), "compliance: country missing");
        require(d.compliance.isModuleRegistered(address(d.lockup)), "compliance: lockup missing");

        // Forced recovery evicts the lost wallet from the registry, which needs this grant.
        require(d.identityRegistry.hasRole(Roles.AGENT_ROLE, address(d.token)), "registry: token not agent");

        // The operator roles a regulated instrument needs day to day.
        require(d.identityRegistry.hasRole(Roles.AGENT_ROLE, agent), "registry: agent missing");
        require(d.token.hasRole(Roles.AGENT_ROLE, agent), "token: agent missing");
        require(d.token.hasRole(Roles.CUSTODIAN_ROLE, custodian), "token: custodian missing");
        require(d.token.hasRole(0x00, issuer), "token: issuer missing");

        // The anchored hash matches the file on disk. This is the check the whole anchor exists
        // for: if the document was edited after this script last ran, the two disagree.
        (, bytes32 anchored,) = d.documentRegistry.getDocument(TERMS_NAME);
        require(anchored == d.termsHash, "documents: terms hash mismatch");
        require(anchored == keccak256(bytes(vm.readFile(TERMS_PATH))), "documents: terms drifted from disk");
    }

    /// @dev Prints the address book a deployment needs to be usable afterwards.
    function _logDeployment(Deployment memory d, address issuer, address agent, address custodian) internal pure {
        console2.log("SecurityToken       ", address(d.token));
        console2.log("IdentityRegistry    ", address(d.identityRegistry));
        console2.log("ModularCompliance   ", address(d.compliance));
        console2.log("MaxHoldersModule    ", address(d.maxHolders));
        console2.log("CountryRestriction  ", address(d.countryRestriction));
        console2.log("LockupModule        ", address(d.lockup));
        console2.log("DocumentRegistry    ", address(d.documentRegistry));
        console2.log("issuer              ", issuer);
        console2.log("agent               ", agent);
        console2.log("custodian           ", custodian);
        console2.logBytes32(d.termsHash);
    }
}
