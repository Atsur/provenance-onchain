const { expect } = require("chai");
const { ethers, upgrades } = require("hardhat");
const { MerkleTree } = require("merkletreejs");
const keccak256 = require("keccak256");

describe("ProvenanceHub", function () {
    let hub;
    let admin, committer, pauser, user;
    const MIN_BATCH_SIZE = 100;
    const MAX_BATCH_SIZE = 1000;

    beforeEach(async function () {
        [admin, committer, pauser, user] = await ethers.getSigners();

        const ProvenanceHub = await ethers.getContractFactory("ProvenanceHub");
        hub = await upgrades.deployProxy(
            ProvenanceHub,
            [admin.address, MIN_BATCH_SIZE, MAX_BATCH_SIZE],
            { initializer: "initialize", kind: "uups" }
        );
        await hub.waitForDeployment();

        // Grant roles
        await hub.grantRole(await hub.BATCH_COMMITTER_ROLE(), committer.address);
        await hub.grantRole(await hub.PAUSER_ROLE(), pauser.address);
    });

    describe("Initialization", function () {
        it("Should initialize with correct values", async function () {
            expect(await hub.minBatchSize()).to.equal(MIN_BATCH_SIZE);
            expect(await hub.maxBatchSize()).to.equal(MAX_BATCH_SIZE);
            expect(await hub.hasRole(await hub.DEFAULT_ADMIN_ROLE(), admin.address)).to.be.true;
        });

        it("Should revert with zero admin", async function () {
            const ProvenanceHub = await ethers.getContractFactory("ProvenanceHub");
            await expect(
                upgrades.deployProxy(
                    ProvenanceHub,
                    [ethers.ZeroAddress, MIN_BATCH_SIZE, MAX_BATCH_SIZE],
                    { initializer: "initialize", kind: "uups" }
                )
            ).to.be.revertedWithCustomError(hub, "ZeroAddress");
        });
    });

    describe("Batch Committing", function () {
        it("Should commit a batch successfully", async function () {
            const merkleRoot = ethers.keccak256(ethers.toUtf8Bytes("test root"));
            const arweaveTxId = ethers.keccak256(ethers.toUtf8Bytes("arweave-tx-123"));
            const eventCount = 500;

            await expect(
                hub.connect(committer).commitBatch(merkleRoot, arweaveTxId, eventCount)
            )
                .to.emit(hub, "BatchCommitted")
                .withArgs(0, merkleRoot, arweaveTxId, eventCount, anyValue, committer.address);

            expect(await hub.batchCount()).to.equal(1);
            expect(await hub.usedMerkleRoots(merkleRoot)).to.be.true;
            expect(await hub.usedArweaveTxIds(arweaveTxId)).to.be.true;
        });

        it("Should revert if not authorized", async function () {
            const merkleRoot = ethers.keccak256(ethers.toUtf8Bytes("test root"));
            const arweaveTxId = ethers.keccak256(ethers.toUtf8Bytes("arweave-tx-123"));

            await expect(
                hub.connect(user).commitBatch(merkleRoot, arweaveTxId, 500)
            ).to.be.revertedWithCustomError(hub, "AccessControlUnauthorizedAccount");
        });

        it("Should revert with invalid batch size", async function () {
            const merkleRoot = ethers.keccak256(ethers.toUtf8Bytes("test root"));
            const arweaveTxId = ethers.keccak256(ethers.toUtf8Bytes("arweave-tx-123"));

            await expect(
                hub.connect(committer).commitBatch(merkleRoot, arweaveTxId, 50)
            ).to.be.revertedWithCustomError(hub, "InvalidBatchSize");

            await expect(
                hub.connect(committer).commitBatch(merkleRoot, arweaveTxId, 2000)
            ).to.be.revertedWithCustomError(hub, "InvalidBatchSize");
        });

        it("Should revert with duplicate Merkle root", async function () {
            const merkleRoot = ethers.keccak256(ethers.toUtf8Bytes("test root"));
            const arweaveTxId1 = ethers.keccak256(ethers.toUtf8Bytes("arweave-tx-1"));
            const arweaveTxId2 = ethers.keccak256(ethers.toUtf8Bytes("arweave-tx-2"));

            await hub.connect(committer).commitBatch(merkleRoot, arweaveTxId1, 500);

            await expect(
                hub.connect(committer).commitBatch(merkleRoot, arweaveTxId2, 600)
            ).to.be.revertedWithCustomError(hub, "DuplicateMerkleRoot");
        });

        it("Should revert with duplicate Arweave TX ID", async function () {
            const merkleRoot1 = ethers.keccak256(ethers.toUtf8Bytes("test root 1"));
            const merkleRoot2 = ethers.keccak256(ethers.toUtf8Bytes("test root 2"));
            const arweaveTxId = ethers.keccak256(ethers.toUtf8Bytes("arweave-tx-123"));

            await hub.connect(committer).commitBatch(merkleRoot1, arweaveTxId, 500);

            await expect(
                hub.connect(committer).commitBatch(merkleRoot2, arweaveTxId, 600)
            ).to.be.revertedWithCustomError(hub, "DuplicateArweaveTxId");
        });
    });

    describe("Proof Verification", function () {
        it("Should verify valid Merkle proof", async function () {
            // Create Merkle tree
            const events = ["event1", "event2", "event3", "event4"];
            const leaves = events.map(event => keccak256(event));
            const tree = new MerkleTree(leaves, keccak256, { sortPairs: true });
            const merkleRoot = tree.getHexRoot();

            // Commit batch
            const arweaveTxId = ethers.keccak256(ethers.toUtf8Bytes("arweave-tx-123"));
            await hub.connect(committer).commitBatch(merkleRoot, arweaveTxId, events.length);

            // Get proof for first event
            const leaf = keccak256("event1");
            const proof = tree.getHexProof(leaf);

            // Verify proof
            const isValid = await hub.verifyProofView(0, leaf, proof);
            expect(isValid).to.be.true;
        });

        it("Should reject invalid Merkle proof", async function () {
            const merkleRoot = ethers.keccak256(ethers.toUtf8Bytes("test root"));
            const arweaveTxId = ethers.keccak256(ethers.toUtf8Bytes("arweave-tx-123"));

            await hub.connect(committer).commitBatch(merkleRoot, arweaveTxId, 100);

            const invalidProof = [ethers.keccak256(ethers.toUtf8Bytes("wrong"))];
            const isValid = await hub.verifyProofView(0, ethers.keccak256(ethers.toUtf8Bytes("wrong leaf")), invalidProof);
            expect(isValid).to.be.false;
        });

        it("Should revert for non-existent batch", async function () {
            const proof = [];
            await expect(
                hub.verifyProofView(999, ethers.keccak256(ethers.toUtf8Bytes("leaf")), proof)
            ).to.be.revertedWithCustomError(hub, "BatchNotFound");
        });
    });

    describe("Configuration", function () {
        it("Should update batch size limits", async function () {
            await expect(
                hub.connect(admin).setBatchSizeLimits(200, 2000)
            )
                .to.emit(hub, "BatchSizeLimitsUpdated")
                .withArgs(200, 2000);

            expect(await hub.minBatchSize()).to.equal(200);
            expect(await hub.maxBatchSize()).to.equal(2000);
        });

        it("Should revert if not admin", async function () {
            await expect(
                hub.connect(user).setBatchSizeLimits(200, 2000)
            ).to.be.revertedWithCustomError(hub, "AccessControlUnauthorizedAccount");
        });
    });

    describe("Pause Functionality", function () {
        it("Should pause and unpause", async function () {
            await hub.connect(pauser).pauseBatchCommits();
            expect(await hub.paused()).to.be.true;

            await hub.connect(pauser).unpauseBatchCommits();
            expect(await hub.paused()).to.be.false;
        });

        it("Should prevent batch commits when paused", async function () {
            await hub.connect(pauser).pauseBatchCommits();

            const merkleRoot = ethers.keccak256(ethers.toUtf8Bytes("test root"));
            const arweaveTxId = ethers.keccak256(ethers.toUtf8Bytes("arweave-tx-123"));

            await expect(
                hub.connect(committer).commitBatch(merkleRoot, arweaveTxId, 500)
            ).to.be.revertedWithCustomError(hub, "EnforcedPause");
        });
    });

    describe("View Functions", function () {
        it("Should get batch information", async function () {
            const merkleRoot = ethers.keccak256(ethers.toUtf8Bytes("test root"));
            const arweaveTxId = ethers.keccak256(ethers.toUtf8Bytes("arweave-tx-123"));
            const eventCount = 500;

            await hub.connect(committer).commitBatch(merkleRoot, arweaveTxId, eventCount);

            const batch = await hub.getBatch(0);
            expect(batch.merkleRoot).to.equal(merkleRoot);
            expect(batch.arweaveTxId).to.equal(arweaveTxId);
            expect(batch.eventCount).to.equal(eventCount);
        });

        it("Should get latest batch ID", async function () {
            // No batches yet
            await expect(hub.getLatestBatchId()).to.be.revertedWithCustomError(hub, "BatchNotFound");

            // Commit a batch
            const merkleRoot = ethers.keccak256(ethers.toUtf8Bytes("test root"));
            const arweaveTxId = ethers.keccak256(ethers.toUtf8Bytes("arweave-tx-123"));
            await hub.connect(committer).commitBatch(merkleRoot, arweaveTxId, 500);

            expect(await hub.getLatestBatchId()).to.equal(0);
        });
    });
});

// Helper for anyValue matcher
function anyValue() {
    return true;
}

