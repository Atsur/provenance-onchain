/**
 * commitBatch.js — Anchor a Merkle batch on AtsurProvenance
 *
 * Builds a Merkle tree from sample CIDOC event hashes and calls anchorBatch().
 * In production the event leaves come from CidocEventEncoder.js and the
 * Arweave TX ID from a real Arweave upload.
 *
 * Usage:
 *   npx hardhat run scripts/commitBatch.js --network liskSepolia
 *
 * Required .env:
 *   PROVENANCE_ADDRESS   AtsurProvenance proxy address
 *   REGISTRY_ADDRESS     AtsurActorRegistry proxy address
 *   SUBMITTER_ACTOR_ID   bytes32 actorId of the submitter (must be registered)
 *   PRIVATE_KEY          Signer with BATCH_COMMITTER_ROLE
 */

const hre = require("hardhat");
const { MerkleTree } = require("merkletreejs");
const keccak256 = require("keccak256");
require("dotenv").config();

async function main() {
    const [signer] = await hre.ethers.getSigners();

    const provenanceAddress = process.env.PROVENANCE_ADDRESS;
    const submitterActorId  = process.env.SUBMITTER_ACTOR_ID;

    if (!provenanceAddress) throw new Error("PROVENANCE_ADDRESS not set");
    if (!submitterActorId)  throw new Error("SUBMITTER_ACTOR_ID not set");

    const provenance = await hre.ethers.getContractAt("AtsurProvenance", provenanceAddress);

    // ── Build Merkle tree ────────────────────────────────────────────────────
    // In production: leaves come from CidocEventEncoder.computeEventLeaf()
    // and computeAuthorshipLeaf(), uploaded to Arweave before calling anchorBatch.
    const rawEvents = [
        "cidoc-event-1",
        "cidoc-event-2",
        "cidoc-event-3",
    ];

    const leaves = rawEvents.map(e => keccak256(e));
    const tree   = new MerkleTree(leaves, keccak256, { sortPairs: true });
    const root   = tree.getHexRoot();

    // In production: real Arweave TX ID from the upload response
    const arweaveTxId = hre.ethers.keccak256(
        hre.ethers.toUtf8Bytes(`arweave-tx-${Date.now()}`)
    );

    const eventCount = rawEvents.length;
    const nonce      = Math.floor(Math.random() * 1e9);   // production: use a DB sequence
    const eventType  = "E12_Production";

    console.log("=== Anchor Batch ===");
    console.log("Signer:          ", signer.address);
    console.log("Provenance:      ", provenanceAddress);
    console.log("Submitter actorId:", submitterActorId);
    console.log("Merkle root:     ", root);
    console.log("Arweave TX ID:   ", arweaveTxId);
    console.log("Event count:     ", eventCount);
    console.log("Nonce:           ", nonce);
    console.log("");

    const tx = await provenance.anchorBatch(
        root,
        arweaveTxId,
        submitterActorId,
        eventCount,
        nonce,
        eventType
    );
    console.log("Transaction hash:", tx.hash);

    const receipt = await tx.wait();
    console.log("Confirmed in block:", receipt.blockNumber);

    // Parse BatchAnchored event to get batchId
    const iface   = provenance.interface;
    const batchLog = receipt.logs
        .map(log => { try { return iface.parseLog(log); } catch { return null; } })
        .find(e => e && e.name === "BatchAnchored");

    if (batchLog) {
        const batchId = batchLog.args.batchId;
        console.log("\n=== Batch Anchored ===");
        console.log("Batch ID:  ", batchId);
        console.log("Root:      ", batchLog.args.merkleRoot);
        console.log("Arweave:   ", batchLog.args.arweaveTxId);
        console.log("Submitter: ", batchLog.args.submitterActorId);
        console.log("Events:    ", batchLog.args.eventCount.toString());

        // Verify a leaf proof as sanity check
        const proofForLeaf0 = tree.getHexProof(leaves[0]);
        const verified = await provenance.verifyProofView(
            batchId,
            "0x" + leaves[0].toString("hex"),
            proofForLeaf0
        );
        console.log("\nLeaf[0] proof valid:", verified);
    }
}

main()
    .then(() => process.exit(0))
    .catch((err) => { console.error(err); process.exit(1); });
