// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import { Script, console } from "forge-std/Script.sol";
import { AtsurActorRegistry } from "../contracts/AtsurActorRegistry.sol";
import { AtsurProvenance }    from "../contracts/AtsurProvenance.sol";
import { ERC1967Proxy }       from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";

/**
 * @title DeployScript
 * @notice Deploys both AtsurActorRegistry and AtsurProvenance as UUPS proxies.
 *
 * DEPLOYMENT ORDER:
 *   1. Deploy AtsurActorRegistry implementation + proxy
 *   2. Deploy AtsurProvenance implementation + proxy (takes registry address)
 *   3. Grant roles to operator wallet
 *   4. Deploy TimelockController and transfer UPGRADER_ROLE to it, revoke from deployer
 *      (mandatory on every non-local network — see _isLocalNetwork)
 *   5. (Optional) Transfer DEFAULT_ADMIN_ROLE to Safe multisig, revoke deployer admin
 *
 * ENVIRONMENT VARIABLES (set in .env):
 *   PRIVATE_KEY         Deployer private key
 *   OPERATOR_ADDRESS    Hot wallet: OPERATOR_ROLE on registry, BATCH_COMMITTER_ROLE on provenance
 *   PAUSER_ADDRESS      Emergency pauser: PAUSER_ROLE on provenance (defaults to deployer)
 *   MULTISIG_ADDRESS    (Optional) Safe multisig — admin transferred here if set. Must already be
 *                       a deployed contract (checked on-chain). Leave empty for local-only testing.
 *   TIMELOCK_DELAY      Upgrade delay in seconds for the TimelockController (default 172800 = 48h).
 *                       Must be >= 86400 (24h) on any non-local network.
 *   CONFIRM_MAINNET     Must equal "I_UNDERSTAND_THIS_IS_MAINNET" to deploy to a known mainnet
 *                       chain ID (Polygon 137, Lisk 1135).
 *
 * USAGE (Lisk Sepolia):
 *   forge script scripts/Deploy.s.sol \
 *     --rpc-url $LISK_SEPOLIA_RPC \
 *     --broadcast \
 *     --verify \
 *     --verifier blockscout \
 *     --verifier-url https://sepolia-blockscout.lisk.com/api
 */
contract DeployScript is Script {

    uint256 public constant MIN_BATCH_SIZE = 1;     // Testnet: low for easy testing
    uint256 public constant MAX_BATCH_SIZE = 1000;

    uint256 public constant DEFAULT_TIMELOCK_DELAY      = 172800; // 48 hours
    uint256 public constant MIN_PRODUCTION_TIMELOCK_DELAY = 86400; // 24 hours

    uint256 public constant POLYGON_MAINNET_CHAIN_ID = 137;
    uint256 public constant LISK_MAINNET_CHAIN_ID    = 1135;

    function run() external {
        _checkMainnetConfirmation();

        uint256 deployerKey   = vm.envUint("PRIVATE_KEY");
        address deployer      = vm.addr(deployerKey);
        address operator      = vm.envAddress("OPERATOR_ADDRESS");
        address pauser        = vm.envOr("PAUSER_ADDRESS", deployer);
        address multisig      = vm.envOr("MULTISIG_ADDRESS", address(0));
        uint256 timelockDelay = vm.envOr("TIMELOCK_DELAY", DEFAULT_TIMELOCK_DELAY);

        bool isLocal = _isLocalNetwork();

        if (!isLocal) {
            require(timelockDelay >= MIN_PRODUCTION_TIMELOCK_DELAY, "Timelock delay too short for production");
        }

        if (multisig != address(0)) {
            require(
                multisig.code.length > 0,
                "MULTISIG_ADDRESS is an EOA, not a contract. Deploy a Gnosis Safe first."
            );
        }

        console.log("=== Atsur Deployment ===");
        console.log("Deployer: ", deployer);
        console.log("Operator: ", operator);
        console.log("Pauser:   ", pauser);
        console.log("Chain ID: ", block.chainid);

        vm.startBroadcast(deployerKey);

        // 1. AtsurActorRegistry
        console.log("\n[1/2] Deploying AtsurActorRegistry...");
        AtsurActorRegistry registryImpl = new AtsurActorRegistry();

        ERC1967Proxy registryProxy = new ERC1967Proxy(
            address(registryImpl),
            abi.encodeWithSelector(AtsurActorRegistry.initialize.selector, deployer, operator)
        );
        AtsurActorRegistry registry = AtsurActorRegistry(address(registryProxy));
        console.log("  proxy:", address(registry));
        console.log("  ver:  ", registry.version());

        // 2. AtsurProvenance
        console.log("\n[2/2] Deploying AtsurProvenance...");
        AtsurProvenance provenanceImpl = new AtsurProvenance();

        ERC1967Proxy provenanceProxy = new ERC1967Proxy(
            address(provenanceImpl),
            abi.encodeWithSelector(
                AtsurProvenance.initialize.selector,
                deployer,
                address(registry),
                MIN_BATCH_SIZE,
                MAX_BATCH_SIZE
            )
        );
        AtsurProvenance provenance = AtsurProvenance(address(provenanceProxy));
        console.log("  proxy:", address(provenance));
        console.log("  ver:  ", provenance.version());

        // 3. Grant roles
        console.log("\n[3] Granting roles...");
        provenance.grantRole(provenance.BATCH_COMMITTER_ROLE(), operator);
        provenance.grantRole(provenance.PAUSER_ROLE(), pauser);

        // 4. Deploy TimelockController and transfer UPGRADER_ROLE — mandatory on non-local
        //    networks, not opt-in. UPGRADER_ROLE is self-administered as of initialize()
        //    (_setRoleAdmin(UPGRADER_ROLE, UPGRADER_ROLE)), so the deployer — who already holds
        //    UPGRADER_ROLE from initialize() — can still grant it onward to the timelock here.
        address timelockAddress;
        if (!isLocal) {
            console.log("\n[4] Deploying TimelockController...");
            console.log("  delay (seconds):", timelockDelay);
            address timelockAdmin = multisig != address(0) ? multisig : deployer;

            address[] memory proposers = new address[](1);
            proposers[0] = timelockAdmin;
            address[] memory executors = new address[](1);
            executors[0] = timelockAdmin;

            TimelockController timelock = new TimelockController(
                timelockDelay,
                proposers,
                executors,
                address(0) // self-administration disabled
            );
            timelockAddress = address(timelock);
            console.log("  TimelockController:", timelockAddress);

            bytes32 upgraderRole = registry.UPGRADER_ROLE();

            console.log("  Granting UPGRADER_ROLE to timelock on registry...");
            registry.grantRole(upgraderRole, timelockAddress);
            console.log("  Granting UPGRADER_ROLE to timelock on provenance...");
            provenance.grantRole(upgraderRole, timelockAddress);

            console.log("  Revoking UPGRADER_ROLE from deployer...");
            registry.revokeRole(upgraderRole, deployer);
            provenance.revokeRole(upgraderRole, deployer);

            console.log("  Upgrades now require TimelockController proposal + delay.");
        }

        // 5. Transfer admin to multisig if set
        if (multisig != address(0)) {
            console.log("\n[5] Transferring admin to multisig...");
            bytes32 adminRole = registry.DEFAULT_ADMIN_ROLE();
            registry.grantRole(adminRole, multisig);
            provenance.grantRole(adminRole, multisig);
            registry.renounceRole(adminRole, deployer);
            provenance.renounceRole(adminRole, deployer);
            console.log("  Admin transferred. Deployer admin renounced.");
        }

        vm.stopBroadcast();

        console.log("\n=== Deployment Complete ===");
        console.log("AtsurActorRegistry proxy: ", address(registry));
        console.log("AtsurActorRegistry impl:  ", address(registryImpl));
        console.log("AtsurProvenance proxy:    ", address(provenance));
        console.log("AtsurProvenance impl:     ", address(provenanceImpl));
        if (timelockAddress != address(0)) {
            console.log("TimelockController:       ", timelockAddress);
        }
        console.log("\nCopy to .env:");
        console.log("REGISTRY_ADDRESS=<registry-proxy>");
        console.log("PROVENANCE_ADDRESS=<provenance-proxy>");
        console.log("\nSee DEPLOYMENT.md for post-deployment verification steps.");
    }

    /// @dev Reverts unless CONFIRM_MAINNET is explicitly set when targeting a known mainnet.
    function _checkMainnetConfirmation() internal view {
        if (block.chainid == POLYGON_MAINNET_CHAIN_ID || block.chainid == LISK_MAINNET_CHAIN_ID) {
            string memory confirmation = vm.envOr("CONFIRM_MAINNET", string(""));
            require(
                keccak256(bytes(confirmation)) == keccak256(bytes("I_UNDERSTAND_THIS_IS_MAINNET")),
                "Set CONFIRM_MAINNET=I_UNDERSTAND_THIS_IS_MAINNET to deploy to mainnet"
            );
        }
    }

    /// @dev Local dev chains (Anvil default / Hardhat default) skip mandatory timelock deployment.
    function _isLocalNetwork() internal view returns (bool) {
        return block.chainid == 31337 || block.chainid == 1337;
    }
}
