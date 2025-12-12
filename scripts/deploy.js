const hre = require("hardhat");
const { upgrades } = require("hardhat");

async function main() {
    const signers = await hre.ethers.getSigners();
    
    if (signers.length === 0) {
        throw new Error(
            "No signers found. Please:\n" +
            "1. Set PRIVATE_KEY in your .env file, or\n" +
            "2. Use --network hardhat for local testing"
        );
    }
    
    const deployer = signers[0];
    const networkName = hre.network.name;
    const chainId = (await hre.ethers.provider.getNetwork()).chainId;
    
    console.log("\n=== Deployment Configuration ===");
    console.log("Network:", networkName);
    console.log("Chain ID:", chainId.toString());
    console.log("Deploying contracts with account:", deployer.address);
    
    const balance = await deployer.provider.getBalance(deployer.address);
    console.log("Account balance:", hre.ethers.formatEther(balance), "ETH");
    
    if (balance === 0n && networkName !== "hardhat") {
        console.warn("⚠️  Warning: Account has zero balance. Deployment may fail.");
        console.warn("   Please fund your account before deploying to a live network.");
    }

    // Configuration
    const MIN_BATCH_SIZE = 100;
    const MAX_BATCH_SIZE = 1000;

    // Deploy implementation
    console.log("\nDeploying ProvenanceHub implementation...");
    const ProvenanceHub = await hre.ethers.getContractFactory("ProvenanceHub");
    
    // Deploy as UUPS upgradeable proxy
    const hub = await upgrades.deployProxy(
        ProvenanceHub,
        [deployer.address, MIN_BATCH_SIZE, MAX_BATCH_SIZE],
        { 
            initializer: "initialize",
            kind: "uups"
        }
    );

    await hub.waitForDeployment();
    const hubAddress = await hub.getAddress();
    const implementationAddress = await upgrades.erc1967.getImplementationAddress(hubAddress);

    console.log("\n=== Deployment Summary ===");
    console.log("Hub (Proxy):", hubAddress);
    console.log("Implementation:", implementationAddress);
    console.log("Version:", await hub.version());
    console.log("Min batch size:", (await hub.minBatchSize()).toString());
    console.log("Max batch size:", (await hub.maxBatchSize()).toString());

    // Verify deployment
    console.log("\n=== Verification ===");
    console.log("Waiting for block confirmations...");
    await hub.deploymentTransaction()?.wait(5);

    // Auto-verify on block explorer (if API key is set)
    if (process.env.LISK_SEPOLIA_API_KEY || process.env.POLYGONSCAN_API_KEY) {
        try {
            console.log("Verifying implementation contract...");
            await hre.run("verify:verify", {
                address: implementationAddress,
                constructorArguments: [],
            });
            console.log("Implementation verified!");
        } catch (error) {
            console.log("Verification failed:", error.message);
        }
    }

    console.log("\n=== Next Steps ===");
    console.log("1. Grant BATCH_COMMITTER_ROLE:");
    console.log(`   await hub.grantRole(await hub.BATCH_COMMITTER_ROLE(), "0x...")`);
    console.log("2. Grant PAUSER_ROLE:");
    console.log(`   await hub.grantRole(await hub.PAUSER_ROLE(), "0x...")`);
    console.log("3. Test batch commitment");
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });

