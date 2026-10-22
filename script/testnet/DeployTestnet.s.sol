// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console2} from "forge-std/console2.sol";
import {VmSafe} from "forge-std/Vm.sol";

import {Deploy} from "../Deploy.s.sol";
import {DividendDistributor} from "../../src/compliance/modules/DividendDistributor.sol";
import {Roles} from "../../src/Roles.sol";
import {TestnetDesk} from "./TestnetDesk.sol";
import {TestnetEURC} from "./TestnetEURC.sol";

/**
 * @title DeployTestnet
 * @notice Public testnet deployment of the demo (Base Sepolia by default): the seven contracts of
 *         Deploy.s.sol with the same parameters, the dividend distributor, a testnet desk standing
 *         in for the KYC provider, the issuer's primary issuance and the paying agent, and a seeded
 *         register so the demo does not start empty.
 * @dev What differs from Deploy.s.sol, and why:
 *      - Every role goes to the broadcasting account. `_deploy` runs its admin-gated wiring as the
 *        executing account, so the issuer must be the deployer anyway; on a demo, agent and
 *        custodian follow it.
 *      - The lockup is shortened to TESTNET_LOCKUP_PERIOD after `_deploy`, through the module's own
 *        `setLockupPeriod`: the 365 days Deploy.s.sol sets would keep every visitor's notes locked
 *        for a year. The holder cap stays at Deploy.s.sol's value (see TestnetDesk).
 *      - The distributor is attached with `addModule` after `_deploy`, as the scenario suites do.
 *        It pays in TestnetEURC, which only the desk mints.
 *      - Two jurisdictions are restricted: North Korea (408) and Iran (364), the two the FATF calls
 *        on its members to apply countermeasures to (FATF statement of June 2026).
 *      - The seeded wallets have addresses derived from a hash, not from a key, so nobody can sign
 *        for them and each keeps the state it was seeded with. Each one exercises a different
 *        outcome of the transfer gate (see `_seed`).
 *
 *      Nothing here depends on an external feed or on a time window, so there is no second script.
 *      Before anything is sent, forge simulates the whole run, including `_verifyTestnet`, which
 *      reads every outcome the app shows through the token's own `canTransfer` and the modules'
 *      `moduleCheck`: a wiring mistake reverts the run. On a broadcast it writes the deployment
 *      file the app reads.
 *
 *      Usage (Base Sepolia):
 *        forge script script/testnet/DeployTestnet.s.sol --rpc-url https://sepolia.base.org \
 *          --account <keystore> --broadcast
 *      Optional env: DEPLOYMENT_FILE.
 */
contract DeployTestnet is Deploy {
    /*//////////////////////////////////////////////////////////////
                          TESTNET CONFIGURATION
    //////////////////////////////////////////////////////////////*/

    /// @dev Holding period on the testnet deployment, set through the module's own setter.
    uint64 internal constant TESTNET_LOCKUP_PERIOD = 5 minutes;

    /// @dev Restricted jurisdictions, ISO 3166-1 numeric.
    uint16 internal constant NORTH_KOREA = 408;
    uint16 internal constant IRAN = 364;

    /// @dev Countries of the seeded investors, ISO 3166-1 numeric.
    uint16 internal constant SPAIN = 724;
    uint16 internal constant GERMANY = 276;
    uint16 internal constant FRANCE = 250;
    uint16 internal constant PORTUGAL = 620;
    uint16 internal constant ITALY = 380;

    /// @dev Attestation validity of the seeded investors, and of the one seeded to lapse.
    uint64 internal constant SEED_KYC_VALIDITY = 3_650 days;
    uint64 internal constant LAPSING_KYC_VALIDITY = 1 hours;

    /// @dev Seeded positions, in whole notes (18 decimals).
    uint256 internal constant SETTLED_NOTES = 500e18;
    uint256 internal constant PARTLY_FROZEN_NOTES = 250e18;
    uint256 internal constant PARTLY_FROZEN_LOCKED = 100e18;
    uint256 internal constant FROZEN_NOTES = 100e18;
    uint256 internal constant SUSPENDED_NOTES = 100e18;
    uint256 internal constant LAPSED_NOTES = 50e18;

    /*//////////////////////////////////////////////////////////////
                                 TYPES
    //////////////////////////////////////////////////////////////*/

    /// @notice The seeded wallets, one per outcome of the transfer gate.
    struct Seeds {
        address settled; // verified, unrestricted, holds notes: transfers from it pass once the lockup ends
        address partlyFrozen; // part of its balance frozen: InsufficientUnfrozenBalance above the free part
        address frozen; // wallet frozen: SenderAddressFrozen and RecipientAddressFrozen
        address suspended; // identity removed, balance kept: SenderNotVerified
        address restricted; // verified in a restricted country: rejected by CountryRestrictionModule
        address unverified; // never registered: RecipientNotVerified
        address lapsed; // attestation lapses an hour after deployment: verified, then not
    }

    /// @notice Everything the testnet run deploys besides the seven contracts `run` returns.
    struct TestnetDeployment {
        DividendDistributor distributor;
        TestnetDesk desk;
        TestnetEURC currency;
        uint256 deployBlock;
    }

    /*//////////////////////////////////////////////////////////////
                                 STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice The testnet contracts of the last run, for tests and the deployment file.
    /// @dev Not named `testnet`: forge treats any public function starting with `test` as a test.
    TestnetDeployment public demo;

    /*//////////////////////////////////////////////////////////////
                                 SCRIPT
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Deploys, wires and seeds the demo, then writes the deployment file on a broadcast.
     * @dev The broadcasting account is read as `tx.origin`, for the reason Deploy.run gives.
     * @return d The seven contracts Deploy.s.sol deploys.
     */
    function run() external override returns (Deployment memory d) {
        // tx.origin only finds the broadcasting account, as in Deploy.run; no contract reads it.
        address deployer = tx.origin;
        uint256 deployBlock = block.number;

        vm.startBroadcast();
        d = _deploy(deployer, deployer, deployer);
        (TestnetDesk desk, DividendDistributor distributor) = _deployDemo(d, deployer);
        _seed(d, desk);
        vm.stopBroadcast();

        demo = TestnetDeployment({
            distributor: distributor, desk: desk, currency: TestnetEURC(desk.currency()), deployBlock: deployBlock
        });

        _verifyTestnet(d, deployer);

        // Only on a real broadcast: a dry run must not overwrite the file with addresses never deployed.
        if (vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)) _writeDeployment(d);

        _logDeployment(d, deployer, deployer, deployer);
        console2.log("DividendDistributor ", address(distributor));
        console2.log("TestnetDesk         ", address(desk));
        console2.log("TestnetEURC         ", desk.currency());
    }

    /*//////////////////////////////////////////////////////////////
                               DEMO WIRING
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Deploys the desk and the distributor, grants the desk its three roles, shortens the
     *      lockup and restricts the two jurisdictions. Runs as the deployer, who holds every role.
     */
    function _deployDemo(Deployment memory d, address deployer)
        internal
        returns (TestnetDesk desk, DividendDistributor distributor)
    {
        desk = new TestnetDesk(deployer, address(d.identityRegistry), address(d.token));
        distributor = new DividendDistributor(address(d.compliance), address(d.token), desk.currency(), deployer);
        d.compliance.addModule(address(distributor));
        desk.setDistributor(address(distributor));

        // The desk's three powers: register its caller, mint to its caller, deposit coupons.
        d.identityRegistry.grantRole(Roles.AGENT_ROLE, address(desk));
        d.token.grantRole(d.token.DEFAULT_ADMIN_ROLE(), address(desk));
        distributor.grantRole(Roles.AGENT_ROLE, address(desk));

        d.lockup.setLockupPeriod(TESTNET_LOCKUP_PERIOD);
        d.countryRestriction.setCountryRestricted(NORTH_KOREA, true);
        d.countryRestriction.setCountryRestricted(IRAN, true);
    }

    /**
     * @dev Seeds one wallet per outcome of the transfer gate, then pays the first coupon so the
     *      distributor does not start at zero. Supply after seeding: 1,000 notes.
     */
    function _seed(Deployment memory d, TestnetDesk desk) internal {
        Seeds memory s = seeds();
        uint64 longKyc = uint64(block.timestamp) + SEED_KYC_VALIDITY;

        d.identityRegistry.registerIdentity(s.settled, SPAIN, true, longKyc);
        d.token.mint(s.settled, SETTLED_NOTES);

        d.identityRegistry.registerIdentity(s.partlyFrozen, GERMANY, true, longKyc);
        d.token.mint(s.partlyFrozen, PARTLY_FROZEN_NOTES);
        d.token.freezePartialTokens(s.partlyFrozen, PARTLY_FROZEN_LOCKED);

        d.identityRegistry.registerIdentity(s.frozen, FRANCE, true, longKyc);
        d.token.mint(s.frozen, FROZEN_NOTES);
        d.token.setAddressFrozen(s.frozen, true);

        d.identityRegistry.registerIdentity(s.suspended, PORTUGAL, true, longKyc);
        d.token.mint(s.suspended, SUSPENDED_NOTES);
        d.identityRegistry.removeIdentity(s.suspended);

        d.identityRegistry.registerIdentity(s.restricted, IRAN, true, longKyc);

        d.identityRegistry.registerIdentity(s.lapsed, ITALY, true, uint64(block.timestamp) + LAPSING_KYC_VALIDITY);
        d.token.mint(s.lapsed, LAPSED_NOTES);

        desk.payCoupon();
    }

    /**
     * @notice The seeded wallets. Derived from a hash of a label rather than from a key, so nobody
     *         holds a key for them and they keep the state `_seed` gives them.
     * @return s One address per gate outcome.
     */
    function seeds() public pure returns (Seeds memory s) {
        s.settled = _seedAddress("settled holder");
        s.partlyFrozen = _seedAddress("partly frozen holder");
        s.frozen = _seedAddress("frozen holder");
        s.suspended = _seedAddress("suspended holder");
        s.restricted = _seedAddress("restricted-country investor");
        s.unverified = _seedAddress("unverified wallet");
        s.lapsed = _seedAddress("lapsed attestation");
    }

    function _seedAddress(string memory label) internal pure returns (address) {
        return address(uint160(uint256(keccak256(bytes(string.concat("rwa-demo seed: ", label))))));
    }

    /*//////////////////////////////////////////////////////////////
                             SANITY CHECKS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Simulation only, after stopBroadcast, so a failure reverts the run before anything is
     *      sent. Reads, through the protocol's own views, every gate outcome the app shows for the
     *      seeds, and the wiring each desk function needs. Views only: nothing it does is broadcast
     *      or left behind in a test.
     */
    function _verifyTestnet(Deployment memory d, address deployer) internal view {
        TestnetDesk desk = demo.desk;
        DividendDistributor distributor = demo.distributor;
        Seeds memory s = seeds();

        // The parameters Deploy.s.sol sets, except the lockup.
        require(d.maxHolders.maxHolders() == MAX_HOLDERS, "maxHolders: not the Deploy.s.sol cap");
        require(d.lockup.lockupPeriod() == TESTNET_LOCKUP_PERIOD, "lockup: testnet period not set");
        require(d.compliance.modules().length == 4, "compliance: module count");
        require(d.compliance.isModuleRegistered(address(distributor)), "compliance: distributor missing");

        // The desk's three roles, and that it is wired to this deployment.
        require(d.identityRegistry.hasRole(Roles.AGENT_ROLE, address(desk)), "desk: not agent on registry");
        require(d.token.hasRole(d.token.DEFAULT_ADMIN_ROLE(), address(desk)), "desk: cannot mint");
        require(distributor.hasRole(Roles.AGENT_ROLE, address(desk)), "desk: cannot deposit");
        require(desk.distributor() == address(distributor), "desk: distributor not wired");
        require(desk.owner() == deployer, "desk: owner");
        require(TestnetEURC(desk.currency()).minter() == address(desk), "currency: desk is not the minter");

        // The seeded register and the first coupon.
        require(d.token.totalSupply() == 1_000e18, "seed: supply");
        require(d.maxHolders.holderCount() == 5, "seed: holder count");
        require(distributor.dividendsPerShare() > 0, "seed: first coupon not paid");

        // Each seed's outcome, as the app reads it. The lockup is still running at deployment, so
        // a transfer out of a seeded position is checked against the lockup first.
        uint256 one = 1e18;
        require(!d.lockup.moduleCheck(s.settled, s.partlyFrozen, one), "settled: lockup should be running");
        require(d.token.canTransfer(address(0), s.settled, one), "settled: cannot receive");
        require(!d.token.canTransfer(s.settled, s.unverified, one), "unverified: accepted");
        require(!d.token.canTransfer(s.settled, s.frozen, one), "frozen: accepted as recipient");
        require(!d.token.canTransfer(s.settled, s.restricted, one), "restricted: accepted");
        require(!d.countryRestriction.moduleCheck(s.settled, s.restricted, one), "restricted: country rule passes");
        require(!d.token.canTransfer(s.suspended, s.settled, one), "suspended: can send");
        require(!d.token.canTransfer(address(0), s.suspended, one), "suspended: can receive");
        require(d.token.frozenTokens(s.partlyFrozen) == PARTLY_FROZEN_LOCKED, "partlyFrozen: frozen amount");
        require(d.token.isFrozen(s.frozen), "frozen: not frozen");
        require(d.identityRegistry.isVerified(s.lapsed), "lapsed: should start verified");
        require(!d.identityRegistry.isVerified(s.unverified), "unverified: verified");

        // The anchored terms, which the app re-hashes in the browser.
        (, bytes32 anchored,) = d.documentRegistry.getDocument(TERMS_NAME);
        require(anchored == TERMS_HASH, "documents: terms not anchored");
    }

    /*//////////////////////////////////////////////////////////////
                            DEPLOYMENT FILE
    //////////////////////////////////////////////////////////////*/

    /// @dev Writes the addresses the app needs to app/src/config/deployments/<chainId>.json.
    function _writeDeployment(Deployment memory d) internal {
        Seeds memory s = seeds();
        string memory seedsKey = "seeds";
        vm.serializeAddress(seedsKey, "settled", s.settled);
        vm.serializeAddress(seedsKey, "partlyFrozen", s.partlyFrozen);
        vm.serializeAddress(seedsKey, "frozen", s.frozen);
        vm.serializeAddress(seedsKey, "suspended", s.suspended);
        vm.serializeAddress(seedsKey, "restricted", s.restricted);
        vm.serializeAddress(seedsKey, "unverified", s.unverified);
        string memory seedsJson = vm.serializeAddress(seedsKey, "lapsed", s.lapsed);

        uint256[] memory restricted = new uint256[](2);
        restricted[0] = NORTH_KOREA;
        restricted[1] = IRAN;

        string memory root = "deployment";
        vm.serializeUint(root, "chainId", block.chainid);
        vm.serializeUint(root, "deployBlock", demo.deployBlock);
        vm.serializeAddress(root, "token", address(d.token));
        vm.serializeAddress(root, "identityRegistry", address(d.identityRegistry));
        vm.serializeAddress(root, "compliance", address(d.compliance));
        vm.serializeAddress(root, "maxHolders", address(d.maxHolders));
        vm.serializeAddress(root, "countryRestriction", address(d.countryRestriction));
        vm.serializeAddress(root, "lockup", address(d.lockup));
        vm.serializeAddress(root, "documentRegistry", address(d.documentRegistry));
        vm.serializeAddress(root, "distributor", address(demo.distributor));
        vm.serializeAddress(root, "desk", address(demo.desk));
        vm.serializeAddress(root, "currency", address(demo.currency));
        vm.serializeBytes32(root, "termsName", TERMS_NAME);
        vm.serializeUint(root, "restrictedCountries", restricted);
        root = vm.serializeString(root, "seeds", seedsJson);

        vm.writeJson(root, deploymentFile());
    }

    /// @notice Where the deployment file lives: DEPLOYMENT_FILE, or the app's file for this chain id.
    function deploymentFile() public view returns (string memory) {
        string memory defaultPath = string.concat("app/src/config/deployments/", vm.toString(block.chainid), ".json");
        return vm.envOr("DEPLOYMENT_FILE", defaultPath);
    }
}
