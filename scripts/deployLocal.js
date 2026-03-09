/**
 * deployLocal.js — Deploy and seed both Atsur contracts on a local Hardhat node.
 *
 * Uses Hardhat's built-in test accounts so no .env is needed.
 * Saves addresses to .deployments/31337.json for other scripts to consume.
 *
 * Usage (two options):
 *
 *   Option A — in-process (ephemeral, gone when the process exits):
 *     npx hardhat run scripts/deployLocal.js
 *
 *   Option B — persistent local node (recommended for frontend / backend dev):
 *     Terminal 1:  npx hardhat node
 *     Terminal 2:  npx hardhat run scripts/deployLocal.js --network localhost
 *
 * After running, addresses are in .deployments/31337.json and printed to stdout.
 */

const { ethers, upgrades } = require("hardhat");
const { syncDeployment } = require("./syncDeployment");

// ─── Hardhat well-known test accounts (mnemonic: test test ... junk) ────────
// Index  Purpose
//   0    deployer  — runs the script
//   1    admin     — DEFAULT_ADMIN_ROLE (stands in for multisig on local)
//   2    operator  — OPERATOR_ROLE + BATCH_COMMITTER_ROLE + PAUSER_ROLE
//   3    artist    — test actor (E21_Person)
//   4    collector — test actor (E21_Person)
//   5    gallery   — test actor (E74_Group)
//   6    nga       — test actor (E40_LegalBody, will delegate a verifier)
//   7    verifier  — test verifier under nga (wallet only, opaque on-chain)
//   8    stranger  — no roles, useful for negative tests

async function main() {
    const signers   = await ethers.getSigners();
    const deployer  = signers[0];
    const admin     = signers[1];
    const operator  = signers[2];
    const artistW   = signers[3];
    const collectorW = signers[4];
    const galleryW  = signers[5];
    const ngaW      = signers[6];

    const network = await ethers.provider.getNetwork();

    console.log("=== Atsur Local Deployment ===");
    console.log("Chain ID:", network.chainId.toString());
    console.log("Deployer:  ", deployer.address);
    console.log("Admin:     ", admin.address);
    console.log("Operator:  ", operator.address);
    console.log("");

    // ── 1. AtsurActorRegistry ────────────────────────────────────────────────
    console.log("[1/2] Deploying AtsurActorRegistry...");
    const RegistryFactory = await ethers.getContractFactory("AtsurActorRegistry");
    const registry = await upgrades.deployProxy(
        RegistryFactory,
        [admin.address, operator.address],
        { initializer: "initialize", kind: "uups" }
    );
    await registry.waitForDeployment();
    const registryAddress = await registry.getAddress();
    const registryImpl    = await upgrades.erc1967.getImplementationAddress(registryAddress);
    console.log("  proxy:  ", registryAddress);
    console.log("  impl:   ", registryImpl);

    // ── 2. AtsurProvenance ───────────────────────────────────────────────────
    console.log("\n[2/2] Deploying AtsurProvenance...");
    const ProvenanceFactory = await ethers.getContractFactory("AtsurProvenance");
    const provenance = await upgrades.deployProxy(
        ProvenanceFactory,
        [admin.address, registryAddress, 1, 1000],
        { initializer: "initialize", kind: "uups" }
    );
    await provenance.waitForDeployment();
    const provenanceAddress = await provenance.getAddress();
    const provenanceImpl    = await upgrades.erc1967.getImplementationAddress(provenanceAddress);
    console.log("  proxy:  ", provenanceAddress);
    console.log("  impl:   ", provenanceImpl);

    // ── 3. Grant roles ───────────────────────────────────────────────────────
    console.log("\n[3] Granting roles...");
    const OPERATOR_ROLE        = await registry.OPERATOR_ROLE();
    const BATCH_COMMITTER_ROLE = await provenance.BATCH_COMMITTER_ROLE();
    const PAUSER_ROLE          = await provenance.PAUSER_ROLE();

    // Admin does the granting (holds DEFAULT_ADMIN_ROLE after deployment)
    let tx;
    tx = await registry.connect(admin).grantRole(OPERATOR_ROLE, operator.address);
    await tx.wait();
    tx = await provenance.connect(admin).grantRole(BATCH_COMMITTER_ROLE, operator.address);
    await tx.wait();
    tx = await provenance.connect(admin).grantRole(PAUSER_ROLE, operator.address);
    await tx.wait();
    console.log("  ✓ OPERATOR_ROLE          -> operator");
    console.log("  ✓ BATCH_COMMITTER_ROLE   -> operator");
    console.log("  ✓ PAUSER_ROLE            -> operator");

    // ── 4. Seed test actors ──────────────────────────────────────────────────
    console.log("\n[4] Seeding test actors...");

    // Derive actorIds and commitments (mirrors IdentityCommitmentService.js logic)
    const salt        = ethers.randomBytes(32);
    const artistId    = ethers.keccak256(ethers.toUtf8Bytes("uuid-artist-001"));
    const collectorId = ethers.keccak256(ethers.toUtf8Bytes("uuid-collector-001"));
    const galleryId   = ethers.keccak256(ethers.toUtf8Bytes("uuid-gallery-001"));
    const ngaId       = ethers.keccak256(ethers.toUtf8Bytes("uuid-nga-001"));

    function makeCommitment(providerUserId, atsurUuid) {
        return ethers.keccak256(
            ethers.solidityPacked(
                ["string", "string", "string", "bytes32"],
                ["smile_id", providerUserId, atsurUuid, salt]
            )
        );
    }

    const ActorType = { E21_Person: 0, E74_Group: 1, E40_LegalBody: 2 };

    // artist — E21_Person
    tx = await registry.connect(operator).registerActor(
        artistId,
        ActorType.E21_Person,
        makeCommitment("smile-artist-001", "uuid-artist-001"),
        "smile_id",
        artistW.address
    );
    await tx.wait();
    console.log("  ✓ artist    registered:", artistId.slice(0, 10) + "...", "->", artistW.address);

    // collector — E21_Person
    tx = await registry.connect(operator).registerActor(
        collectorId,
        ActorType.E21_Person,
        makeCommitment("smile-collector-001", "uuid-collector-001"),
        "smile_id",
        collectorW.address
    );
    await tx.wait();
    console.log("  ✓ collector registered:", collectorId.slice(0, 10) + "...", "->", collectorW.address);

    // gallery — E74_Group
    tx = await registry.connect(operator).registerActor(
        galleryId,
        ActorType.E74_Group,
        makeCommitment("smile-gallery-001", "uuid-gallery-001"),
        "smile_id",
        galleryW.address
    );
    await tx.wait();
    console.log("  ✓ gallery   registered:", galleryId.slice(0, 10) + "...", "->", galleryW.address);

    // nga — E40_LegalBody (will also be used as batch submitter)
    tx = await registry.connect(operator).registerActor(
        ngaId,
        ActorType.E40_LegalBody,
        makeCommitment("smile-nga-001", "uuid-nga-001"),
        "smile_id",
        ngaW.address
    );
    await tx.wait();
    console.log("  ✓ nga       registered:", ngaId.slice(0, 10) + "...", "->", ngaW.address);

    // ── 5. Seed a test batch ─────────────────────────────────────────────────
    console.log("\n[5] Anchoring a seed provenance batch...");

    // Build a two-leaf Merkle tree (authorship + a creation event)
    const { MerkleTree } = require("merkletreejs");
    const keccak256       = require("keccak256");

    const AUTHORSHIP_LEAF_PREFIX = ethers.keccak256(ethers.toUtf8Bytes("ATSUR_AUTHORSHIP_V1"));
    const artworkId = ethers.keccak256(ethers.toUtf8Bytes("artwork-seed-001"));

    const authorshipLeaf = ethers.keccak256(
        ethers.solidityPacked(
            ["bytes32", "bytes32", "bytes32"],
            [AUTHORSHIP_LEAF_PREFIX, artworkId, artistId]
        )
    );
    const creationLeaf = ethers.keccak256(ethers.toUtf8Bytes("cidoc-E12-seed-event-001"));

    const leaves = [
        Buffer.from(authorshipLeaf.slice(2), "hex"),
        Buffer.from(creationLeaf.slice(2), "hex"),
    ];
    const tree = new MerkleTree(leaves, keccak256, { sortPairs: true });
    const root = "0x" + tree.getRoot().toString("hex");

    const arweaveTxId  = ethers.keccak256(ethers.toUtf8Bytes("arweave-local-seed-001"));
    const nonce        = 1n;

    tx = await provenance.connect(operator).anchorBatch(
        root,
        arweaveTxId,
        2,
        ngaId,
        ethers.zeroPadValue(ethers.toBeHex(nonce), 32),
        "E12_Production"
    );
    const receipt = await tx.wait();

    // Parse BatchAnchored event for the batchId
    const iface    = provenance.interface;
    const batchLog = receipt.logs
        .map(log => { try { return iface.parseLog(log); } catch { return null; } })
        .find(e => e && e.name === "BatchAnchored");

    const seedBatchId = batchLog ? batchLog.args.batchId : null;
    console.log("  ✓ seed batch anchored:", seedBatchId?.slice(0, 10) + "...");
    console.log("    merkle root:", root);

    // Verify authorship as a sanity check
    const authorshipProof = tree.getHexProof(leaves[0]);
    const authorshipOk    = await provenance.checkAuthorship(
        seedBatchId, artworkId, artistId, authorshipProof
    );
    console.log("  ✓ checkAuthorship sanity:", authorshipOk ? "PASS" : "FAIL");

    // ── 6. Save deployment manifest ──────────────────────────────────────────
    const manifest = {
        network:        "localhost",
        chainId:        network.chainId.toString(),
        deployedAt:     new Date().toISOString(),
        contracts: {
            AtsurActorRegistry: {
                proxy: registryAddress,
                implementation: registryImpl,
            },
            AtsurProvenance: {
                proxy: provenanceAddress,
                implementation: provenanceImpl,
            },
        },
        roles: {
            admin:    admin.address,
            operator: operator.address,
        },
        seedActors: {
            artist:    { actorId: artistId,    wallet: artistW.address },
            collector: { actorId: collectorId, wallet: collectorW.address },
            gallery:   { actorId: galleryId,   wallet: galleryW.address },
            nga:       { actorId: ngaId,        wallet: ngaW.address },
        },
        seedBatch: {
            batchId:   seedBatchId,
            artworkId: artworkId,
            root:      root,
        },
    };

    console.log("\n[6] Saving deployment manifest...");
    syncDeployment(manifest, "31337.json");

    // ── Summary ──────────────────────────────────────────────────────────────
    console.log("\n=== Deployment Complete ===");
    console.log("AtsurActorRegistry proxy:", registryAddress);
    console.log("AtsurProvenance proxy:   ", provenanceAddress);

    console.log("\n--- Hardhat test accounts ---");
    const labels = ["deployer", "admin   ", "operator", "artist  ", "collector", "gallery ", "nga     ", "verifier", "stranger"];
    for (let i = 0; i < Math.min(9, signers.length); i++) {
        console.log(`  [${i}] ${labels[i]}  ${signers[i].address}`);
    }

    console.log("\n--- Quick usage ---");
    console.log(`REGISTRY_ADDRESS=${registryAddress}`);
    console.log(`PROVENANCE_ADDRESS=${provenanceAddress}`);
    console.log(`SEED_BATCH_ID=${seedBatchId}`);
    console.log(`ARTWORK_ID=${artworkId}`);
    console.log(`ARTIST_ACTOR_ID=${artistId}`);
}

main()
    .then(() => process.exit(0))
    .catch((err) => { console.error(err); process.exit(1); });
