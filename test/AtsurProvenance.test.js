const { expect }           = require("chai");
const { ethers, upgrades } = require("hardhat");
const { MerkleTree }       = require("merkletreejs");
const keccak256            = require("keccak256");

/**
 * AtsurProvenance — Hardhat integration tests
 *
 * Covers:
 *   - Initialization
 *   - anchorBatch (all validation paths, registry check, batchId derivation)
 *   - recordArtworkCreation (Merkle proof, actor checks)
 *   - recordCustodyTransfer (verifier checks, Merkle proof)
 *   - recordCertification
 *   - checkAuthorship (deterministic authorship leaf)
 *   - verifyProof / verifyProofView / verifyProvenanceEvent
 *   - setBatchSizeLimits
 *   - pause / unpause
 *   - setActorRegistry
 *   - UUPS upgradeability
 */
describe("AtsurProvenance", function () {

    // ─────────────────────────────────────────────
    // HELPERS
    // ─────────────────────────────────────────────

    function makeActorId(uuid) {
        return ethers.keccak256(ethers.toUtf8Bytes(uuid));
    }

    function makeCommitment(provider, providerUserId, atsurUuid, salt) {
        return ethers.keccak256(
            ethers.solidityPacked(
                ["string", "string", "string", "bytes32"],
                [provider, providerUserId, atsurUuid, salt]
            )
        );
    }

    function buildMerkleTree(leaves) {
        // leaves: array of hex strings (0x...)
        const bufs = leaves.map(l => Buffer.from(l.slice(2), "hex"));
        return new MerkleTree(bufs, keccak256, { sortPairs: true });
    }

    function getHexProof(tree, leaf) {
        const buf = Buffer.from(leaf.slice(2), "hex");
        return tree.getHexProof(buf);
    }

    function computeAuthorshipLeaf(artworkId, creatorActorId) {
        const prefix = ethers.keccak256(ethers.toUtf8Bytes("ATSUR_AUTHORSHIP_V1"));
        return ethers.keccak256(
            ethers.solidityPacked(
                ["bytes32", "bytes32", "bytes32"],
                [prefix, artworkId, creatorActorId]
            )
        );
    }

    const ActorType = { E21_Person: 0, E74_Group: 1, E40_LegalBody: 2 };
    const SALT      = ethers.keccak256(ethers.toUtf8Bytes("test-salt"));

    function makeArweaveTxId(seed) {
        return ethers.keccak256(ethers.toUtf8Bytes(`arweave-${seed}`));
    }

    // ─────────────────────────────────────────────
    // FIXTURES
    // ─────────────────────────────────────────────

    let registry, provenance;
    let admin, committer, pauser, user, stranger;

    // Registered actors
    let artistActorId, ngaActorId, collectorActorId, submitterActorId;

    const MIN = 1;
    const MAX = 1000;

    beforeEach(async function () {
        [admin, committer, pauser, user, stranger] = await ethers.getSigners();

        // Deploy registry
        const RegistryFactory = await ethers.getContractFactory("AtsurActorRegistry");
        registry = await upgrades.deployProxy(
            RegistryFactory,
            [admin.address, admin.address], // admin also acts as operator for tests
            { initializer: "initialize", kind: "uups" }
        );
        await registry.waitForDeployment();

        // Deploy provenance
        const ProvenanceFactory = await ethers.getContractFactory("AtsurProvenance");
        provenance = await upgrades.deployProxy(
            ProvenanceFactory,
            [admin.address, await registry.getAddress(), MIN, MAX],
            { initializer: "initialize", kind: "uups" }
        );
        await provenance.waitForDeployment();

        // Grant roles on provenance
        await provenance.grantRole(await provenance.BATCH_COMMITTER_ROLE(), committer.address);
        await provenance.grantRole(await provenance.PAUSER_ROLE(), pauser.address);

        // Register test actors in registry
        artistActorId    = makeActorId("artist-uuid");
        collectorActorId = makeActorId("collector-uuid");
        ngaActorId       = makeActorId("nga-uuid");
        submitterActorId = makeActorId("submitter-uuid");

        const signers = [user, stranger, pauser, committer];
        const uuids   = ["artist-uuid", "collector-uuid", "nga-uuid", "submitter-uuid"];
        const types   = [ActorType.E21_Person, ActorType.E21_Person, ActorType.E40_LegalBody, ActorType.E74_Group];

        for (let i = 0; i < uuids.length; i++) {
            const actorId    = makeActorId(uuids[i]);
            const commitment = makeCommitment("smile_id", `uid-${i}`, uuids[i], SALT);
            await registry.connect(admin).registerActor(
                actorId, types[i], commitment, "smile_id", signers[i].address
            );
        }
    });

    // ─────────────────────────────────────────────
    // INITIALIZATION
    // ─────────────────────────────────────────────

    describe("Initialization", function () {
        it("sets minBatchSize, maxBatchSize, actorRegistry", async function () {
            expect(await provenance.minBatchSize()).to.equal(MIN);
            expect(await provenance.maxBatchSize()).to.equal(MAX);
            expect(await provenance.actorRegistry()).to.equal(await registry.getAddress());
        });

        it("grants DEFAULT_ADMIN_ROLE to admin", async function () {
            expect(await provenance.hasRole(await provenance.DEFAULT_ADMIN_ROLE(), admin.address)).to.be.true;
        });

        it("reverts with zero admin", async function () {
            const Factory = await ethers.getContractFactory("AtsurProvenance");
            await expect(
                upgrades.deployProxy(
                    Factory,
                    [ethers.ZeroAddress, await registry.getAddress(), MIN, MAX],
                    { kind: "uups" }
                )
            ).to.be.revertedWithCustomError(provenance, "ZeroAddress");
        });

        it("reverts with invalid batch size config (min > max)", async function () {
            const Factory = await ethers.getContractFactory("AtsurProvenance");
            await expect(
                upgrades.deployProxy(
                    Factory,
                    [admin.address, await registry.getAddress(), 500, 100],
                    { kind: "uups" }
                )
            ).to.be.revertedWithCustomError(provenance, "InvalidBatchSize");
        });
    });

    // ─────────────────────────────────────────────
    // anchorBatch
    // ─────────────────────────────────────────────

    describe("anchorBatch", function () {
        let eventLeaf, merkleRoot, arweaveTxId, nonce;

        beforeEach(function () {
            eventLeaf   = ethers.keccak256(ethers.toUtf8Bytes("cidoc-event-001"));
            merkleRoot  = ethers.keccak256(ethers.toUtf8Bytes("root-001"));
            arweaveTxId = makeArweaveTxId("tx-001");
            nonce       = ethers.keccak256(ethers.toUtf8Bytes("nonce-1"));
        });

        it("anchors a batch and emits BatchAnchored", async function () {
            await expect(
                provenance.connect(committer).anchorBatch(
                    merkleRoot, arweaveTxId, 5, submitterActorId, nonce, "E12_Production"
                )
            )
                .to.emit(provenance, "BatchAnchored")
                .withArgs(anyValue, merkleRoot, arweaveTxId, submitterActorId, 5, anyValue);
        });

        it("returns a deterministic batchId (keccak of timestamp+submitter+nonce)", async function () {
            const tx      = await provenance.connect(committer).anchorBatch(
                merkleRoot, arweaveTxId, 5, submitterActorId, nonce, "E12_Production"
            );
            const receipt = await tx.wait();
            const event   = receipt.logs.find(l => l.fragment?.name === "BatchAnchored");
            const batchId = event.args[0];
            expect(batchId).to.not.equal(ethers.ZeroHash);
        });

        it("marks merkleRoot and arweaveTxId as used", async function () {
            await provenance.connect(committer).anchorBatch(
                merkleRoot, arweaveTxId, 5, submitterActorId, nonce, "E12_Production"
            );
            expect(await provenance.usedMerkleRoots(merkleRoot)).to.be.true;
            expect(await provenance.usedArweaveTxIds(arweaveTxId)).to.be.true;
        });

        it("reverts for non-committer", async function () {
            await expect(
                provenance.connect(stranger).anchorBatch(
                    merkleRoot, arweaveTxId, 5, submitterActorId, nonce, "E12_Production"
                )
            ).to.be.revertedWithCustomError(provenance, "AccessControlUnauthorizedAccount");
        });

        it("reverts if eventCount below minBatchSize", async function () {
            await provenance.connect(admin).setBatchSizeLimits(5, 1000);
            await expect(
                provenance.connect(committer).anchorBatch(
                    merkleRoot, arweaveTxId, 3, submitterActorId, nonce, "E12_Production"
                )
            ).to.be.revertedWithCustomError(provenance, "InvalidBatchSize");
        });

        it("reverts with duplicate merkle root", async function () {
            await provenance.connect(committer).anchorBatch(
                merkleRoot, arweaveTxId, 5, submitterActorId, nonce, "E12_Production"
            );
            const arweaveTxId2 = makeArweaveTxId("tx-002");
            const nonce2       = ethers.keccak256(ethers.toUtf8Bytes("nonce-2"));
            await expect(
                provenance.connect(committer).anchorBatch(
                    merkleRoot, arweaveTxId2, 5, submitterActorId, nonce2, "E12_Production"
                )
            ).to.be.revertedWithCustomError(provenance, "DuplicateMerkleRoot");
        });

        it("reverts with duplicate Arweave TX ID", async function () {
            await provenance.connect(committer).anchorBatch(
                merkleRoot, arweaveTxId, 5, submitterActorId, nonce, "E12_Production"
            );
            const merkleRoot2 = ethers.keccak256(ethers.toUtf8Bytes("root-002"));
            const nonce2      = ethers.keccak256(ethers.toUtf8Bytes("nonce-2"));
            await expect(
                provenance.connect(committer).anchorBatch(
                    merkleRoot2, arweaveTxId, 5, submitterActorId, nonce2, "E12_Production"
                )
            ).to.be.revertedWithCustomError(provenance, "DuplicateArweaveTxId");
        });

        it("reverts if submitter not in registry", async function () {
            const unknownActor = makeActorId("not-registered");
            await expect(
                provenance.connect(committer).anchorBatch(
                    merkleRoot, arweaveTxId, 5, unknownActor, nonce, "E12_Production"
                )
            ).to.be.revertedWithCustomError(provenance, "SubmitterNotInRegistry");
        });

        // M-21 (SEV-006)
        it("reverts SubmitterNotActive for suspended submitter", async function () {
            const ActorStatus = { Active: 0, Suspended: 1, Revoked: 2 };
            await registry.connect(admin).setActorStatus(submitterActorId, ActorStatus.Suspended);
            await expect(
                provenance.connect(committer).anchorBatch(
                    merkleRoot, arweaveTxId, 5, submitterActorId, nonce, "E12_Production"
                )
            ).to.be.revertedWithCustomError(provenance, "SubmitterNotActive");
        });

        it("reverts with empty eventType", async function () {
            await expect(
                provenance.connect(committer).anchorBatch(
                    merkleRoot, arweaveTxId, 5, submitterActorId, nonce, ""
                )
            ).to.be.revertedWithCustomError(provenance, "EmptyEventType");
        });

        it("reverts with zero arweaveTxId", async function () {
            await expect(
                provenance.connect(committer).anchorBatch(
                    merkleRoot, ethers.ZeroHash, 5, submitterActorId, nonce, "E12_Production"
                )
            ).to.be.revertedWithCustomError(provenance, "InvalidArweaveTxId");
        });

        // SEV-003 fix
        it("reverts InvalidMerkleRoot for zero merkle root", async function () {
            await expect(
                provenance.connect(committer).anchorBatch(
                    ethers.ZeroHash, arweaveTxId, 5, submitterActorId, nonce, "E12_Production"
                )
            ).to.be.revertedWithCustomError(provenance, "InvalidMerkleRoot");
        });

        // SEV-002 fix
        it("reverts BatchAlreadyExists when same nonce+submitter collide in same timestamp", async function () {
            const root1        = ethers.keccak256(ethers.toUtf8Bytes("root-dup-1"));
            const arweave1     = makeArweaveTxId("dup-1");
            const sharedNonce  = ethers.keccak256(ethers.toUtf8Bytes("shared-nonce-collision"));

            const tx1      = await provenance.connect(committer).anchorBatch(
                root1, arweave1, 5, submitterActorId, sharedNonce, "E12_Production"
            );
            const receipt1 = await tx1.wait();
            const block1   = await ethers.provider.getBlock(receipt1.blockNumber);

            // Force the next block to carry the same timestamp as block1
            await ethers.provider.send("evm_setNextBlockTimestamp", [block1.timestamp]);

            const root2    = ethers.keccak256(ethers.toUtf8Bytes("root-dup-2"));
            const arweave2 = makeArweaveTxId("dup-2");

            await expect(
                provenance.connect(committer).anchorBatch(
                    root2, arweave2, 5, submitterActorId, sharedNonce, "E12_Production"
                )
            ).to.be.revertedWithCustomError(provenance, "BatchAlreadyExists");
        });
    });

    // ─────────────────────────────────────────────
    // Helpers to anchor a batch and get batchId
    // ─────────────────────────────────────────────

    async function anchorWithLeaves(leaves) {
        const tree     = buildMerkleTree(leaves);
        const root     = tree.getHexRoot();
        const arweave  = makeArweaveTxId(`tx-${Date.now()}-${Math.random()}`);
        const nonce    = ethers.keccak256(ethers.toUtf8Bytes(`nonce-${Date.now()}`));

        const tx      = await provenance.connect(committer).anchorBatch(
            root, arweave, leaves.length, submitterActorId, nonce, "E12_Production"
        );
        const receipt = await tx.wait();
        const event   = receipt.logs.find(l => l.fragment?.name === "BatchAnchored");
        return { batchId: event.args[0], tree, root };
    }

    // ─────────────────────────────────────────────
    // recordArtworkCreation
    // ─────────────────────────────────────────────

    describe("recordArtworkCreation", function () {
        it("emits ArtworkRegistered after valid proof", async function () {
            const artworkId      = makeActorId("artwork-001");
            const eventLeaf      = ethers.keccak256(ethers.toUtf8Bytes("creation-event-001"));
            const authorshipLeaf = computeAuthorshipLeaf(artworkId, artistActorId);

            const { batchId, tree } = await anchorWithLeaves([eventLeaf, authorshipLeaf]);
            const proof = getHexProof(tree, eventLeaf);

            await expect(
                provenance.connect(committer).recordArtworkCreation(
                    batchId, artworkId, artistActorId, eventLeaf, proof
                )
            )
                .to.emit(provenance, "ArtworkRegistered")
                .withArgs(artworkId, artistActorId, batchId, eventLeaf, anyValue);
        });

        it("reverts with invalid Merkle proof", async function () {
            const artworkId  = makeActorId("artwork-002");
            const eventLeaf  = ethers.keccak256(ethers.toUtf8Bytes("creation-event-002"));
            const { batchId } = await anchorWithLeaves([eventLeaf]);

            const badProof = [ethers.keccak256(ethers.toUtf8Bytes("wrong"))];
            await expect(
                provenance.connect(committer).recordArtworkCreation(
                    batchId, artworkId, artistActorId, eventLeaf, badProof
                )
            ).to.be.revertedWithCustomError(provenance, "InvalidMerkleProof");
        });

        it("reverts if creator actor not active (suspended)", async function () {
            await registry.connect(admin).setActorStatus(artistActorId, 1 /* Suspended */);

            const artworkId  = makeActorId("artwork-003");
            const eventLeaf  = ethers.keccak256(ethers.toUtf8Bytes("creation-event-003"));
            const { batchId, tree } = await anchorWithLeaves([eventLeaf]);
            const proof = getHexProof(tree, eventLeaf);

            await expect(
                provenance.connect(committer).recordArtworkCreation(
                    batchId, artworkId, artistActorId, eventLeaf, proof
                )
            ).to.be.revertedWithCustomError(provenance, "AttestorNotActive");
        });

        it("reverts if batch does not exist", async function () {
            await expect(
                provenance.connect(committer).recordArtworkCreation(
                    ethers.ZeroHash, makeActorId("a"), artistActorId,
                    ethers.keccak256(ethers.toUtf8Bytes("leaf")), []
                )
            ).to.be.revertedWithCustomError(provenance, "BatchNotFound");
        });
    });

    // ─────────────────────────────────────────────
    // recordCustodyTransfer
    // ─────────────────────────────────────────────

    describe("recordCustodyTransfer", function () {
        it("emits CustodyTransferred after valid proof", async function () {
            const artworkId = makeActorId("artwork-transfer-001");
            const eventLeaf = ethers.keccak256(ethers.toUtf8Bytes("transfer-event-001"));

            const { batchId, tree } = await anchorWithLeaves([eventLeaf]);
            const proof = getHexProof(tree, eventLeaf);

            await expect(
                provenance.connect(committer).recordCustodyTransfer(
                    batchId, artworkId,
                    artistActorId, collectorActorId,
                    ngaActorId, ethers.ZeroHash, // no delegated verifier
                    eventLeaf, proof, "sale"
                )
            )
                .to.emit(provenance, "CustodyTransferred")
                .withArgs(artworkId, artistActorId, collectorActorId, ngaActorId, ethers.ZeroHash, batchId, "sale", anyValue);
        });

        it("reverts if recipient not in registry", async function () {
            const unknown   = makeActorId("unknown-collector");
            const artworkId = makeActorId("artwork-transfer-002");
            const eventLeaf = ethers.keccak256(ethers.toUtf8Bytes("transfer-event-002"));
            const { batchId, tree } = await anchorWithLeaves([eventLeaf]);
            const proof = getHexProof(tree, eventLeaf);

            await expect(
                provenance.connect(committer).recordCustodyTransfer(
                    batchId, artworkId, artistActorId, unknown,
                    ngaActorId, ethers.ZeroHash, eventLeaf, proof, "sale"
                )
            ).to.be.revertedWithCustomError(provenance, "RecipientNotInRegistry");
        });

        it("reverts if verifierId provided but verifier not certified", async function () {
            const verifierId = ethers.keccak256(ethers.toUtf8Bytes("uncertified-verifier"));
            // Delegate but don't certify
            await registry.connect(admin).delegateVerifier(ngaActorId, verifierId, false, 0);

            const artworkId = makeActorId("artwork-transfer-003");
            const eventLeaf = ethers.keccak256(ethers.toUtf8Bytes("transfer-event-003"));
            const { batchId, tree } = await anchorWithLeaves([eventLeaf]);
            const proof = getHexProof(tree, eventLeaf);

            await expect(
                provenance.connect(committer).recordCustodyTransfer(
                    batchId, artworkId, artistActorId, collectorActorId,
                    ngaActorId, verifierId, eventLeaf, proof, "sale"
                )
            ).to.be.revertedWithCustomError(provenance, "VerifierNotCertified");
        });

        it("succeeds with a certified verifier", async function () {
            const verifierId = ethers.keccak256(ethers.toUtf8Bytes("certified-verifier"));
            await registry.connect(admin).delegateVerifier(ngaActorId, verifierId, false, 0);
            await registry.connect(admin).certifyVerifierTraining(ngaActorId, verifierId);

            const artworkId = makeActorId("artwork-transfer-004");
            const eventLeaf = ethers.keccak256(ethers.toUtf8Bytes("transfer-event-004"));
            const { batchId, tree } = await anchorWithLeaves([eventLeaf]);
            const proof = getHexProof(tree, eventLeaf);

            await expect(
                provenance.connect(committer).recordCustodyTransfer(
                    batchId, artworkId, artistActorId, collectorActorId,
                    ngaActorId, verifierId, eventLeaf, proof, "sale"
                )
            ).to.emit(provenance, "CustodyTransferred");
        });
    });

    // ─────────────────────────────────────────────
    // recordCertification
    // ─────────────────────────────────────────────

    describe("recordCertification", function () {
        it("emits ArtworkCertified after valid proof", async function () {
            const artworkId = makeActorId("artwork-cert-001");
            const eventLeaf = ethers.keccak256(ethers.toUtf8Bytes("cert-event-001"));
            const { batchId, tree } = await anchorWithLeaves([eventLeaf]);
            const proof = getHexProof(tree, eventLeaf);

            await expect(
                provenance.connect(committer).recordCertification(
                    batchId, artworkId, ngaActorId, ethers.ZeroHash, eventLeaf, proof
                )
            )
                .to.emit(provenance, "ArtworkCertified")
                .withArgs(artworkId, ngaActorId, ethers.ZeroHash, batchId, anyValue);
        });

        it("reverts with invalid proof", async function () {
            const artworkId = makeActorId("artwork-cert-002");
            const eventLeaf = ethers.keccak256(ethers.toUtf8Bytes("cert-event-002"));
            const { batchId } = await anchorWithLeaves([eventLeaf]);
            const badProof = [ethers.keccak256(ethers.toUtf8Bytes("bad"))];

            await expect(
                provenance.connect(committer).recordCertification(
                    batchId, artworkId, ngaActorId, ethers.ZeroHash, eventLeaf, badProof
                )
            ).to.be.revertedWithCustomError(provenance, "InvalidMerkleProof");
        });
    });

    // ─────────────────────────────────────────────
    // checkAuthorship
    // ─────────────────────────────────────────────

    describe("checkAuthorship", function () {
        it("returns true when authorship leaf is in the batch", async function () {
            const artworkId      = makeActorId("artwork-authorship-001");
            const eventLeaf      = ethers.keccak256(ethers.toUtf8Bytes("event-001"));
            const authorshipLeaf = computeAuthorshipLeaf(artworkId, artistActorId);

            const { batchId, tree } = await anchorWithLeaves([eventLeaf, authorshipLeaf]);
            const proof = getHexProof(tree, authorshipLeaf);

            const result = await provenance.checkAuthorship(batchId, artworkId, artistActorId, proof);
            expect(result).to.be.true;
        });

        it("returns false for wrong creator", async function () {
            const artworkId      = makeActorId("artwork-authorship-002");
            const eventLeaf      = ethers.keccak256(ethers.toUtf8Bytes("event-002"));
            const authorshipLeaf = computeAuthorshipLeaf(artworkId, artistActorId);

            const { batchId, tree } = await anchorWithLeaves([eventLeaf, authorshipLeaf]);
            const proof = getHexProof(tree, authorshipLeaf);

            const result = await provenance.checkAuthorship(batchId, artworkId, collectorActorId, proof);
            expect(result).to.be.false;
        });

        it("reverts if batch not found", async function () {
            await expect(
                provenance.checkAuthorship(
                    ethers.ZeroHash,
                    makeActorId("a"), artistActorId, []
                )
            ).to.be.revertedWithCustomError(provenance, "BatchNotFound");
        });
    });

    // ─────────────────────────────────────────────
    // Proof verification
    // ─────────────────────────────────────────────

    describe("Proof verification", function () {
        it("verifyProofView: returns true for valid proof", async function () {
            const leaf = ethers.keccak256(ethers.toUtf8Bytes("leaf-verify-001"));
            const { batchId, tree } = await anchorWithLeaves([leaf]);
            const proof = getHexProof(tree, leaf);

            expect(await provenance.verifyProofView(batchId, leaf, proof)).to.be.true;
        });

        it("verifyProofView: returns false for invalid proof", async function () {
            // Two-leaf tree so root != leaf — empty proof is then invalid
            const leaf  = ethers.keccak256(ethers.toUtf8Bytes("leaf-verify-002"));
            const leaf2 = ethers.keccak256(ethers.toUtf8Bytes("leaf-verify-002b"));
            const { batchId } = await anchorWithLeaves([leaf, leaf2]);

            expect(await provenance.verifyProofView(batchId, leaf, [])).to.be.false;
        });

        it("verifyProvenanceEvent: returns true for valid calldata proof", async function () {
            const leaf = ethers.keccak256(ethers.toUtf8Bytes("leaf-calldata-001"));
            const { batchId, tree } = await anchorWithLeaves([leaf]);
            const proof = getHexProof(tree, leaf);

            expect(await provenance.verifyProvenanceEvent(batchId, leaf, proof)).to.be.true;
        });

        it("verifyProof: emits ProofVerified event", async function () {
            const leaf = ethers.keccak256(ethers.toUtf8Bytes("leaf-emit-001"));
            const { batchId, tree } = await anchorWithLeaves([leaf]);
            const proof = getHexProof(tree, leaf);

            await expect(provenance.verifyProof(batchId, leaf, proof))
                .to.emit(provenance, "ProofVerified")
                .withArgs(batchId, leaf, true);
        });

        it("reverts for non-existent batch", async function () {
            await expect(
                provenance.verifyProofView(ethers.ZeroHash, ethers.ZeroHash, [])
            ).to.be.revertedWithCustomError(provenance, "BatchNotFound");
        });
    });

    // ─────────────────────────────────────────────
    // getBatch
    // ─────────────────────────────────────────────

    describe("getBatch", function () {
        it("returns correct batch data", async function () {
            const leaf     = ethers.keccak256(ethers.toUtf8Bytes("leaf-get-batch"));
            const { batchId, tree } = await anchorWithLeaves([leaf]);
            const root     = tree.getHexRoot();

            const batch = await provenance.getBatch(batchId);
            expect(batch.merkleRoot).to.equal(root);
            expect(batch.submitterActorId).to.equal(submitterActorId);
            expect(batch.eventType).to.equal("E12_Production");
            expect(batch.exists).to.be.true;
        });

        it("reverts for non-existent batch", async function () {
            await expect(provenance.getBatch(ethers.ZeroHash))
                .to.be.revertedWithCustomError(provenance, "BatchNotFound");
        });
    });

    // ─────────────────────────────────────────────
    // Configuration
    // ─────────────────────────────────────────────

    describe("setBatchSizeLimits", function () {
        it("updates limits and emits BatchSizeLimitsUpdated", async function () {
            await expect(provenance.connect(admin).setBatchSizeLimits(10, 500))
                .to.emit(provenance, "BatchSizeLimitsUpdated")
                .withArgs(10, 500);

            expect(await provenance.minBatchSize()).to.equal(10);
            expect(await provenance.maxBatchSize()).to.equal(500);
        });

        it("reverts for non-admin", async function () {
            await expect(provenance.connect(stranger).setBatchSizeLimits(10, 500))
                .to.be.revertedWithCustomError(provenance, "AccessControlUnauthorizedAccount");
        });

        it("reverts if min > max", async function () {
            await expect(provenance.connect(admin).setBatchSizeLimits(500, 10))
                .to.be.revertedWithCustomError(provenance, "InvalidBatchSize");
        });
    });

    describe("setActorRegistry", function () {
        it("allows admin to update registry address", async function () {
            await expect(
                provenance.connect(admin).setActorRegistry(await registry.getAddress())
            ).to.not.be.reverted;
        });

        it("reverts with zero address", async function () {
            await expect(
                provenance.connect(admin).setActorRegistry(ethers.ZeroAddress)
            ).to.be.revertedWithCustomError(provenance, "ZeroAddress");
        });

        it("reverts for non-admin", async function () {
            await expect(
                provenance.connect(stranger).setActorRegistry(await registry.getAddress())
            ).to.be.revertedWithCustomError(provenance, "AccessControlUnauthorizedAccount");
        });
    });

    // ─────────────────────────────────────────────
    // Pause
    // ─────────────────────────────────────────────

    describe("Pause", function () {
        it("pauser can pause; admin can unpause", async function () {
            await provenance.connect(pauser).pauseBatchCommits();
            expect(await provenance.paused()).to.be.true;

            await provenance.connect(admin).unpauseBatchCommits();
            expect(await provenance.paused()).to.be.false;
        });

        // L-2 (SEV-008)
        it("pauser cannot unpause; only admin can", async function () {
            await provenance.connect(pauser).pauseBatchCommits();
            expect(await provenance.paused()).to.be.true;

            await expect(
                provenance.connect(pauser).unpauseBatchCommits()
            ).to.be.revertedWithCustomError(provenance, "AccessControlUnauthorizedAccount");

            await provenance.connect(admin).unpauseBatchCommits();
            expect(await provenance.paused()).to.be.false;
        });

        it("prevents anchorBatch when paused", async function () {
            await provenance.connect(pauser).pauseBatchCommits();

            const root     = ethers.keccak256(ethers.toUtf8Bytes("root-paused"));
            const arweave  = makeArweaveTxId("tx-paused");
            const nonce    = ethers.keccak256(ethers.toUtf8Bytes("nonce-paused"));

            await expect(
                provenance.connect(committer).anchorBatch(
                    root, arweave, 1, submitterActorId, nonce, "E12_Production"
                )
            ).to.be.revertedWithCustomError(provenance, "EnforcedPause");
        });

        it("non-pauser cannot pause", async function () {
            await expect(
                provenance.connect(stranger).pauseBatchCommits()
            ).to.be.revertedWithCustomError(provenance, "AccessControlUnauthorizedAccount");
        });
    });

    // ─────────────────────────────────────────────
    // UUPS Upgradeability
    // ─────────────────────────────────────────────

    describe("Upgradeability (UUPS)", function () {
        it("admin can upgrade to a new implementation", async function () {
            const Factory = await ethers.getContractFactory("AtsurProvenance");
            await expect(upgrades.upgradeProxy(await provenance.getAddress(), Factory)).to.not.be.reverted;
        });

        it("non-admin cannot upgrade", async function () {
            const Factory = await ethers.getContractFactory("AtsurProvenance", stranger);
            await expect(
                upgrades.upgradeProxy(await provenance.getAddress(), Factory)
            ).to.be.reverted;
        });

        // L-6 (SEV-009)
        it("reverts NotAContract when upgrading to an EOA address", async function () {
            await expect(
                provenance.connect(admin).upgradeToAndCall(stranger.address, "0x")
            ).to.be.revertedWithCustomError(provenance, "NotAContract");
        });
    });
});

function anyValue() { return true; }
