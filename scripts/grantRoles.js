const hre = require("hardhat");

async function main() {
    const [deployer] = await hre.ethers.getSigners();
    
    // Get contract address from environment or command line
    const hubAddress = process.env.HUB_ADDRESS || process.argv[2];
    if (!hubAddress) {
        throw new Error("Please provide HUB_ADDRESS environment variable or as first argument");
    }

    const hub = await hre.ethers.getContractAt("ProvenanceHub", hubAddress);

    // Get role addresses from environment
    const batchCommitter = process.env.BATCH_COMMITTER_ADDRESS;
    const pauser = process.env.PAUSER_ADDRESS;

    console.log("Granting roles on:", hubAddress);
    console.log("Deployer:", deployer.address);

    if (batchCommitter) {
        console.log("\nGranting BATCH_COMMITTER_ROLE to:", batchCommitter);
        const tx1 = await hub.grantRole(await hub.BATCH_COMMITTER_ROLE(), batchCommitter);
        await tx1.wait();
        console.log("✓ BATCH_COMMITTER_ROLE granted");
    }

    if (pauser) {
        console.log("\nGranting PAUSER_ROLE to:", pauser);
        const tx2 = await hub.grantRole(await hub.PAUSER_ROLE(), pauser);
        await tx2.wait();
        console.log("✓ PAUSER_ROLE granted");
    }

    console.log("\n=== Role Summary ===");
    if (batchCommitter) {
        const hasCommitterRole = await hub.hasRole(await hub.BATCH_COMMITTER_ROLE(), batchCommitter);
        console.log("BATCH_COMMITTER_ROLE:", hasCommitterRole ? "✓" : "✗");
    }
    if (pauser) {
        const hasPauserRole = await hub.hasRole(await hub.PAUSER_ROLE(), pauser);
        console.log("PAUSER_ROLE:", hasPauserRole ? "✓" : "✗");
    }
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });

