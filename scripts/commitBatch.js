const hre = require("hardhat");
const { MerkleTree } = require("merkletreejs");
const keccak256 = require("keccak256");

async function main() {
    const [signer] = await hre.ethers.getSigners();
    
    const hubAddress = process.env.HUB_ADDRESS || process.argv[2];
    if (!hubAddress) {
        throw new Error("Please provide HUB_ADDRESS");
    }

    const hub = await hre.ethers.getContractAt("ProvenanceHub", hubAddress);

    // Example: Create a Merkle tree from sample events
    const events = [
        "event1",
        "event2",
        "event3",
        "event4"
    ];

    // Hash events
    const leaves = events.map(event => keccak256(event));
    
    // Create Merkle tree
    const tree = new MerkleTree(leaves, keccak256, { sortPairs: true });
    const merkleRoot = tree.getHexRoot();

    // Generate Arweave TX ID (in production, this comes from Arweave upload)
    const arweaveTxId = hre.ethers.keccak256(
        hre.ethers.toUtf8Bytes(`arweave-tx-${Date.now()}`)
    );

    const eventCount = events.length;

    console.log("Committing batch...");
    console.log("Merkle root:", merkleRoot);
    console.log("Arweave TX ID:", arweaveTxId);
    console.log("Event count:", eventCount);

    const tx = await hub.commitBatch(merkleRoot, arweaveTxId, eventCount);
    console.log("Transaction hash:", tx.hash);
    
    const receipt = await tx.wait();
    console.log("Batch committed! Block:", receipt.blockNumber);

    // Get batch info
    const batchId = (await hub.batchCount()) - 1n;
    const batch = await hub.getBatch(batchId);
    console.log("\n=== Batch Info ===");
    console.log("Batch ID:", batchId.toString());
    console.log("Merkle Root:", batch.merkleRoot);
    console.log("Arweave TX ID:", batch.arweaveTxId);
    console.log("Event Count:", batch.eventCount.toString());
    console.log("Timestamp:", batch.timestamp.toString());
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });

