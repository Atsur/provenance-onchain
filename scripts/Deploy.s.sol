// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Script, console} from "forge-std/Script.sol";
import {ProvenanceHub} from "../contracts/ProvenanceHub.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract DeployScript is Script {
    // Configuration
    uint256 public constant MIN_BATCH_SIZE = 100;
    uint256 public constant MAX_BATCH_SIZE = 1000;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deploying from:", deployer);
        console.log("Deployer balance:", deployer.balance / 1e18, "ETH");

        vm.startBroadcast(deployerPrivateKey);

        // Deploy implementation
        console.log("Deploying ProvenanceHub implementation...");
        ProvenanceHub implementation = new ProvenanceHub();
        console.log("Implementation deployed at:", address(implementation));

        // Encode initialization data
        bytes memory initData = abi.encodeWithSelector(
            ProvenanceHub.initialize.selector,
            deployer, // admin
            MIN_BATCH_SIZE,
            MAX_BATCH_SIZE
        );

        // Deploy proxy
        console.log("Deploying ERC1967Proxy...");
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        console.log("Proxy deployed at:", address(proxy));

        // Get hub instance
        ProvenanceHub hub = ProvenanceHub(payable(address(proxy)));

        // Verify deployment
        console.log("\n=== Deployment Summary ===");
        console.log("Hub address:", address(hub));
        console.log("Implementation:", hub.getImplementation());
        console.log("Version:", hub.version());
        console.log("Min batch size:", hub.minBatchSize());
        console.log("Max batch size:", hub.maxBatchSize());
        console.log("Batch count:", hub.batchCount());

        // Grant roles (optional - can be done later)
        console.log("\n=== Role Setup ===");
        console.log("Admin:", deployer);
        console.log("Grant BATCH_COMMITTER_ROLE to deployer? (y/n)");
        // Uncomment to auto-grant:
        // hub.grantRole(hub.BATCH_COMMITTER_ROLE(), deployer);

        vm.stopBroadcast();

        console.log("\n=== Next Steps ===");
        console.log("1. Verify contract on block explorer");
        console.log("2. Grant BATCH_COMMITTER_ROLE to authorized addresses");
        console.log("3. Grant PAUSER_ROLE to emergency pauser");
        console.log("4. Test batch commitment");
    }
}

