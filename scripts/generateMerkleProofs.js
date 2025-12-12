const { MerkleTree } = require("merkletreejs");
const keccak256 = require("keccak256");

/**
 * Generate Merkle tree and proofs using merkletreejs
 * This matches the format expected by OpenZeppelin's MerkleProof library
 */
function generateMerkleTree(leaves) {
    // Convert leaves to Buffers if they're strings
    const leafBuffers = leaves.map(leaf => {
        if (typeof leaf === 'string') {
            return keccak256(leaf);
        }
        return Buffer.from(leaf.slice(2), 'hex'); // Remove '0x' prefix
    });

    // Create Merkle tree
    // OpenZeppelin uses commutativeKeccak256 which sorts pairs before hashing
    // So we need sortPairs: true to match OpenZeppelin's behavior
    const tree = new MerkleTree(leafBuffers, keccak256, {
        sortPairs: true, // Important: OpenZeppelin sorts pairs (commutative hash)
        hashLeaves: false // Leaves are already hashed
    });

    const root = tree.getRoot();
    const proofs = leafBuffers.map(leaf => tree.getProof(leaf));

    return {
        root: '0x' + root.toString('hex'),
        proofs: proofs.map(proof => 
            proof.map(p => '0x' + p.data.toString('hex'))
        ),
        leaves: leafBuffers.map(leaf => '0x' + leaf.toString('hex'))
    };
}

// Example usage
if (require.main === module) {
    const events = ["event0", "event1", "event2", "event3"];
    const result = generateMerkleTree(events);
    
    console.log("Root:", result.root);
    console.log("\nLeaves:");
    result.leaves.forEach((leaf, i) => {
        console.log(`  Leaf ${i}:`, leaf);
    });
    console.log("\nProofs:");
    result.proofs.forEach((proof, i) => {
        console.log(`  Proof ${i}:`, proof);
    });
}

module.exports = { generateMerkleTree };

