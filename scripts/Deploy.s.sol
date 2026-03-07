// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import { Script, console } from "forge-std/Script.sol";
import { AtsurActorRegistry } from "../contracts/AtsurActorRegistry.sol";
import { AtsurProvenance }    from "../contracts/AtsurProvenance.sol";
import { ERC1967Proxy }       from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @title DeployScript
 * @notice Deploys both AtsurActorRegistry and AtsurProvenance as UUPS proxies.
 *
 * DEPLOYMENT ORDER:
 *   1. Deploy AtsurActorRegistry implementation + proxy
 *   2. Deploy AtsurProvenance implementation + proxy (takes registry address)
 *   3. Grant roles to operator wallet
 *   4. (Optional) Transfer DEFAULT_ADMIN_ROLE to Safe multisig, revoke deployer admin
 *
 * ENVIRONMENT VARIABLES (set in .env):
 *   PRIVATE_KEY         Deployer private key
 *   OPERATOR_ADDRESS    Hot wallet: OPERATOR_ROLE on registry, BATCH_COMMITTER_ROLE on provenance
 *   PAUSER_ADDRESS      Emergency pauser: PAUSER_ROLE on provenance (defaults to deployer)
 *   MULTISIG_ADDRESS    (Optional) Safe multisig — admin transferred here if set.
 *                       Leave empty for testnet initial deploy; set before mainnet.
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

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer    = vm.addr(deployerKey);
        address operator    = vm.envAddress("OPERATOR_ADDRESS");
        address pauser      = vm.envOr("PAUSER_ADDRESS", deployer);
        address multisig    = vm.envOr("MULTISIG_ADDRESS", address(0));

        console.log("=== Atsur Deployment (Lisk Sepolia) ===");
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

        // 4. Transfer admin to multisig if set
        if (multisig != address(0)) {
            console.log("\n[4] Transferring admin to multisig...");
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
        console.log("\nCopy to .env:");
        console.log("REGISTRY_ADDRESS=<registry-proxy>");
        console.log("PROVENANCE_ADDRESS=<provenance-proxy>");
        console.log("\nSee MULTISIG.md to set up Safe and transfer admin role.");
    }
}
