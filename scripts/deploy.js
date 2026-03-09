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

    // ─── 1. Deploy AtsurActorRegistry ──────────────────────────────────────────
    console.log("\nDeploying AtsurActorRegistry...");
    const RegistryFactory = await hre.ethers.getContractFactory("AtsurActorRegistry");
    const registry = await upgrades.deployProxy(
        RegistryFactory,
        [deployer.address, deployer.address],
        { initializer: "initialize", kind: "uups" }
    );
    await registry.waitForDeployment();
    const registryAddress = await registry.getAddress();
    console.log("  Registry (proxy):", registryAddress);

    // ─── 2. Deploy AtsurProvenance ────────────────────────────────────────────
    console.log("\nDeploying AtsurProvenance...");
    const AtsurProvenance = await hre.ethers.getContractFactory("AtsurProvenance");
    const hub = await upgrades.deployProxy(
        AtsurProvenance,
        [deployer.address, registryAddress, MIN_BATCH_SIZE, MAX_BATCH_SIZE],
        { initializer: "initialize", kind: "uups" }
    );

    await hub.waitForDeployment();
    const hubAddress = await hub.getAddress();
    const implementationAddress = await upgrades.erc1967.getImplementationAddress(hubAddress);

    console.log("\n=== Deployment Summary ===");
    console.log("AtsurActorRegistry (proxy):", registryAddress);
    console.log("AtsurProvenance (proxy):  ", hubAddress);
    console.log("AtsurProvenance impl:     ", implementationAddress);
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

