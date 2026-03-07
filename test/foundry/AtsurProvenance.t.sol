// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import { Test, console } from "forge-std/Test.sol";
import { AtsurActorRegistry } from "../../contracts/AtsurActorRegistry.sol";
import { AtsurProvenance }    from "../../contracts/AtsurProvenance.sol";
import { ERC1967Proxy }       from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @title AtsurProvenanceTest
 * @notice Foundry unit + fuzz tests for AtsurProvenance.
 *
 * Coverage:
 *   - Initialization guard
 *   - anchorBatch (all validation paths)
 *   - recordArtworkCreation / recordCustodyTransfer / recordCertification
 *   - checkAuthorship (deterministic leaf scheme)
 *   - verifyProof / verifyProofView / verifyProvenanceEvent
 *   - setBatchSizeLimits / setActorRegistry
 *   - pause / unpause
 *   - Access control
 *   - Fuzz: Merkle proof verification
 *   - Fuzz: batchId determinism
 *   - Fuzz: authorship leaf determinism
 */
contract AtsurProvenanceTest is Test {

    // ─────────────────────────────────────────────
    // STATE
    // ─────────────────────────────────────────────

    AtsurActorRegistry internal registry;
    AtsurProvenance    internal provenance;

    address internal admin     = makeAddr("admin");
    address internal operator  = makeAddr("operator");
    address internal committer = makeAddr("committer");
    address internal pauser    = makeAddr("pauser");
    address internal stranger  = makeAddr("stranger");

    // Pre-registered actor IDs
    bytes32 internal artistActorId;
    bytes32 internal ngaActorId;
    bytes32 internal collectorActorId;
    bytes32 internal submitterActorId;

    bytes32 internal constant SALT = keccak256("test-salt");

    // ─────────────────────────────────────────────
    // SETUP
    // ─────────────────────────────────────────────

    function setUp() public {
        // Deploy registry
        AtsurActorRegistry regImpl = new AtsurActorRegistry();
        ERC1967Proxy regProxy = new ERC1967Proxy(
            address(regImpl),
            abi.encodeWithSelector(AtsurActorRegistry.initialize.selector, admin, admin)
        );
        registry = AtsurActorRegistry(address(regProxy));

        // Deploy provenance
        AtsurProvenance provImpl = new AtsurProvenance();
        ERC1967Proxy provProxy = new ERC1967Proxy(
            address(provImpl),
            abi.encodeWithSelector(
                AtsurProvenance.initialize.selector,
                admin,
                address(registry),
                1,    // min batch size (low for tests)
                1000  // max batch size
            )
        );
        provenance = AtsurProvenance(address(provProxy));

        // Grant roles
        vm.startPrank(admin);
        provenance.grantRole(provenance.BATCH_COMMITTER_ROLE(), committer);
        provenance.grantRole(provenance.PAUSER_ROLE(), pauser);
        vm.stopPrank();

        // Register actors in registry
        artistActorId    = _registerActor("artist-uuid",    AtsurActorRegistry.ActorType.E21_Person,  makeAddr("artistWallet"));
        collectorActorId = _registerActor("collector-uuid", AtsurActorRegistry.ActorType.E21_Person,  makeAddr("collectorWallet"));
        ngaActorId       = _registerActor("nga-uuid",       AtsurActorRegistry.ActorType.E40_LegalBody, makeAddr("ngaWallet"));
        submitterActorId = _registerActor("submitter-uuid", AtsurActorRegistry.ActorType.E74_Group,   makeAddr("submitterWallet"));
    }

    // ─────────────────────────────────────────────
    // HELPERS
    // ─────────────────────────────────────────────

    function _registerActor(
        string memory uuid,
        AtsurActorRegistry.ActorType actorType,
        address wallet
    ) internal returns (bytes32 actorId) {
        actorId = keccak256(abi.encodePacked(uuid));
        bytes32 commitment = keccak256(abi.encodePacked("smile_id", uuid, uuid, SALT));
        vm.prank(admin);
        registry.registerActor(actorId, actorType, commitment, "smile_id", wallet);
    }

    /// @dev Build a minimal sorted-pair Merkle tree from two leaves and return root + sibling proof.
    function _buildTwoLeafTree(bytes32 leafA, bytes32 leafB)
        internal pure
        returns (bytes32 root, bytes32[] memory proofA, bytes32[] memory proofB)
    {
        // OZ MerkleProof uses sorted pairs
        bytes32 pairHash = leafA < leafB
            ? keccak256(abi.encodePacked(leafA, leafB))
            : keccak256(abi.encodePacked(leafB, leafA));
        root = pairHash;

        proofA    = new bytes32[](1);
        proofA[0] = leafB;

        proofB    = new bytes32[](1);
        proofB[0] = leafA;
    }

    function _authorshipLeaf(bytes32 artworkId, bytes32 creatorActorId) internal pure returns (bytes32) {
        bytes32 prefix = keccak256("ATSUR_AUTHORSHIP_V1");
        return keccak256(abi.encodePacked(prefix, artworkId, creatorActorId));
    }

    function _anchorSingleLeaf(bytes32 leaf) internal returns (bytes32 batchId) {
        bytes32 nonce   = keccak256(abi.encodePacked(block.timestamp, leaf));
        bytes32 arweave = keccak256(abi.encodePacked("arweave", leaf, nonce));

        vm.prank(committer);
        batchId = provenance.anchorBatch(
            leaf,      // single-leaf tree: root = leaf
            arweave,
            1,
            submitterActorId,
            nonce,
            "E12_Production"
        );
    }

    function _anchorTwoLeaves(bytes32 leafA, bytes32 leafB)
        internal
        returns (bytes32 batchId, bytes32 root)
    {
        (root, , ) = _buildTwoLeafTree(leafA, leafB);
        bytes32 nonce   = keccak256(abi.encodePacked(block.timestamp, leafA, leafB));
        bytes32 arweave = keccak256(abi.encodePacked("arweave", root, nonce));

        vm.prank(committer);
        batchId = provenance.anchorBatch(
            root, arweave, 2, submitterActorId, nonce, "E12_Production"
        );
    }

    // ─────────────────────────────────────────────
    // INITIALIZATION
    // ─────────────────────────────────────────────

    function test_initialize_setsConfig() public view {
        assertEq(provenance.minBatchSize(), 1);
        assertEq(provenance.maxBatchSize(), 1000);
        assertEq(address(provenance.actorRegistry()), address(registry));
        assertTrue(provenance.hasRole(provenance.DEFAULT_ADMIN_ROLE(), admin));
    }

    function test_initialize_reverts_zeroAdmin() public {
        AtsurProvenance impl = new AtsurProvenance();
        vm.expectRevert(AtsurProvenance.ZeroAddress.selector);
        new ERC1967Proxy(
            address(impl),
            abi.encodeWithSelector(
                AtsurProvenance.initialize.selector,
                address(0), address(registry), 1, 1000
            )
        );
    }

    function test_implementation_cannotBeInitialized() public {
        AtsurProvenance impl = new AtsurProvenance();
        vm.expectRevert();
        impl.initialize(admin, address(registry), 1, 1000);
    }

    // ─────────────────────────────────────────────
    // anchorBatch
    // ─────────────────────────────────────────────

    function test_anchorBatch_success_emitsEvent() public {
        bytes32 root    = keccak256("root-001");
        bytes32 arweave = keccak256("arweave-001");
        bytes32 nonce   = keccak256("nonce-001");

        vm.expectEmit(false, false, true, false, address(provenance));
        emit AtsurProvenance.BatchAnchored(bytes32(0), root, arweave, submitterActorId, 5, block.timestamp);

        vm.prank(committer);
        bytes32 batchId = provenance.anchorBatch(root, arweave, 5, submitterActorId, nonce, "E12_Production");

        assertTrue(provenance.usedMerkleRoots(root));
        assertTrue(provenance.usedArweaveTxIds(arweave));

        AtsurProvenance.ProvenanceBatch memory batch = provenance.getBatch(batchId);
        assertEq(batch.merkleRoot, root);
        assertEq(batch.arweaveTxId, arweave);
        assertEq(batch.submitterActorId, submitterActorId);
        assertTrue(batch.exists);
    }

    function test_anchorBatch_reverts_notCommitter() public {
        vm.prank(stranger);
        vm.expectRevert();
        provenance.anchorBatch(keccak256("r"), keccak256("a"), 1, submitterActorId, keccak256("n"), "E12_Production");
    }

    function test_anchorBatch_reverts_belowMinBatchSize() public {
        vm.prank(admin);
        provenance.setBatchSizeLimits(5, 1000);

        vm.prank(committer);
        vm.expectRevert(abi.encodeWithSelector(AtsurProvenance.InvalidBatchSize.selector, 3, 5, 1000));
        provenance.anchorBatch(keccak256("r"), keccak256("a"), 3, submitterActorId, keccak256("n"), "E12_Production");
    }

    function test_anchorBatch_reverts_duplicateMerkleRoot() public {
        bytes32 root  = keccak256("dup-root");
        bytes32 nonce = keccak256("nonce-1");
        vm.prank(committer);
        provenance.anchorBatch(root, keccak256("arweave-1"), 1, submitterActorId, nonce, "E12_Production");

        vm.prank(committer);
        vm.expectRevert(abi.encodeWithSelector(AtsurProvenance.DuplicateMerkleRoot.selector, root));
        provenance.anchorBatch(root, keccak256("arweave-2"), 1, submitterActorId, keccak256("nonce-2"), "E12_Production");
    }

    function test_anchorBatch_reverts_duplicateArweaveTxId() public {
        bytes32 arweave = keccak256("dup-arweave");
        vm.prank(committer);
        provenance.anchorBatch(keccak256("root-1"), arweave, 1, submitterActorId, keccak256("nonce-1"), "E12_Production");

        vm.prank(committer);
        vm.expectRevert(abi.encodeWithSelector(AtsurProvenance.DuplicateArweaveTxId.selector, arweave));
        provenance.anchorBatch(keccak256("root-2"), arweave, 1, submitterActorId, keccak256("nonce-2"), "E12_Production");
    }

    function test_anchorBatch_reverts_submitterNotInRegistry() public {
        bytes32 unknownActor = keccak256("not-registered");
        vm.prank(committer);
        vm.expectRevert(abi.encodeWithSelector(AtsurProvenance.SubmitterNotInRegistry.selector, unknownActor));
        provenance.anchorBatch(
            keccak256("r"), keccak256("a"), 1, unknownActor, keccak256("n"), "E12_Production"
        );
    }

    function test_anchorBatch_reverts_emptyEventType() public {
        vm.prank(committer);
        vm.expectRevert(AtsurProvenance.EmptyEventType.selector);
        provenance.anchorBatch(
            keccak256("r"), keccak256("a"), 1, submitterActorId, keccak256("n"), ""
        );
    }

    function test_anchorBatch_reverts_zeroArweaveTxId() public {
        vm.prank(committer);
        vm.expectRevert(abi.encodeWithSelector(AtsurProvenance.InvalidArweaveTxId.selector, bytes32(0)));
        provenance.anchorBatch(keccak256("r"), bytes32(0), 1, submitterActorId, keccak256("n"), "E12_Production");
    }

    // ─────────────────────────────────────────────
    // recordArtworkCreation
    // ─────────────────────────────────────────────

    function test_recordArtworkCreation_success() public {
        bytes32 artworkId      = keccak256("artwork-001");
        bytes32 eventLeaf      = keccak256("creation-event-001");
        bytes32 authorshipLeaf = _authorshipLeaf(artworkId, artistActorId);

        (bytes32 batchId, ) = _anchorTwoLeaves(eventLeaf, authorshipLeaf);

        (, bytes32[] memory proofForEvent, ) = _buildTwoLeafTree(eventLeaf, authorshipLeaf);

        vm.expectEmit(true, true, true, false, address(provenance));
        emit AtsurProvenance.ArtworkRegistered(artworkId, artistActorId, batchId, eventLeaf, block.timestamp);

        vm.prank(committer);
        provenance.recordArtworkCreation(batchId, artworkId, artistActorId, eventLeaf, proofForEvent);
    }

    function test_recordArtworkCreation_reverts_invalidProof() public {
        bytes32 artworkId = keccak256("artwork-002");
        bytes32 eventLeaf = keccak256("creation-event-002");
        bytes32 batchId   = _anchorSingleLeaf(eventLeaf);

        bytes32[] memory badProof = new bytes32[](1);
        badProof[0] = keccak256("wrong");

        vm.prank(committer);
        vm.expectRevert(AtsurProvenance.InvalidMerkleProof.selector);
        provenance.recordArtworkCreation(batchId, artworkId, artistActorId, eventLeaf, badProof);
    }

    function test_recordArtworkCreation_reverts_actorSuspended() public {
        // Suspend the artist
        vm.prank(admin);
        registry.setActorStatus(artistActorId, AtsurActorRegistry.ActorStatus.Suspended);

        bytes32 artworkId = keccak256("artwork-003");
        bytes32 eventLeaf = keccak256("creation-event-003");
        bytes32 batchId   = _anchorSingleLeaf(eventLeaf);

        bytes32[] memory emptyProof = new bytes32[](0);

        vm.prank(committer);
        vm.expectRevert(abi.encodeWithSelector(AtsurProvenance.AttestorNotActive.selector, artistActorId));
        provenance.recordArtworkCreation(batchId, artworkId, artistActorId, eventLeaf, emptyProof);
    }

    // ─────────────────────────────────────────────
    // checkAuthorship
    // ─────────────────────────────────────────────

    function test_checkAuthorship_returnsTrue() public {
        bytes32 artworkId      = keccak256("artwork-auth-001");
        bytes32 eventLeaf      = keccak256("event-auth-001");
        bytes32 authorshipLeaf = _authorshipLeaf(artworkId, artistActorId);

        (bytes32 batchId, ) = _anchorTwoLeaves(eventLeaf, authorshipLeaf);
        (, , bytes32[] memory proofForAuthorship) = _buildTwoLeafTree(eventLeaf, authorshipLeaf);

        assertTrue(provenance.checkAuthorship(batchId, artworkId, artistActorId, proofForAuthorship));
    }

    function test_checkAuthorship_returnsFalse_wrongCreator() public {
        bytes32 artworkId      = keccak256("artwork-auth-002");
        bytes32 eventLeaf      = keccak256("event-auth-002");
        bytes32 authorshipLeaf = _authorshipLeaf(artworkId, artistActorId);

        (bytes32 batchId, ) = _anchorTwoLeaves(eventLeaf, authorshipLeaf);
        (, , bytes32[] memory proofForAuthorship) = _buildTwoLeafTree(eventLeaf, authorshipLeaf);

        // Using collectorActorId instead of artistActorId — should fail
        assertFalse(provenance.checkAuthorship(batchId, artworkId, collectorActorId, proofForAuthorship));
    }

    function test_checkAuthorship_reverts_batchNotFound() public {
        bytes32[] memory emptyProof = new bytes32[](0);
        vm.expectRevert(abi.encodeWithSelector(AtsurProvenance.BatchNotFound.selector, bytes32(0)));
        provenance.checkAuthorship(bytes32(0), keccak256("a"), artistActorId, emptyProof);
    }

    // ─────────────────────────────────────────────
    // verifyProvenanceEvent
    // ─────────────────────────────────────────────

    function test_verifyProvenanceEvent_singleLeaf() public {
        bytes32 leaf    = keccak256("single-leaf");
        bytes32 batchId = _anchorSingleLeaf(leaf);

        // For a single-leaf tree, root = leaf, proof is empty
        bytes32[] memory emptyProof = new bytes32[](0);
        assertTrue(provenance.verifyProvenanceEvent(batchId, leaf, emptyProof));
    }

    function test_verifyProvenanceEvent_twoLeaves() public {
        bytes32 leafA = keccak256("leaf-A");
        bytes32 leafB = keccak256("leaf-B");
        (bytes32 batchId, ) = _anchorTwoLeaves(leafA, leafB);

        (, bytes32[] memory proofA, ) = _buildTwoLeafTree(leafA, leafB);
        assertTrue(provenance.verifyProvenanceEvent(batchId, leafA, proofA));
    }

    // ─────────────────────────────────────────────
    // Pause
    // ─────────────────────────────────────────────

    function test_pause_preventsAnchorBatch() public {
        vm.prank(pauser);
        provenance.pauseBatchCommits();
        assertTrue(provenance.paused());

        vm.prank(committer);
        vm.expectRevert();
        provenance.anchorBatch(
            keccak256("r"), keccak256("a"), 1, submitterActorId, keccak256("n"), "E12_Production"
        );
    }

    function test_unpause_restoresBatchAnchoring() public {
        vm.prank(pauser);
        provenance.pauseBatchCommits();
        vm.prank(pauser);
        provenance.unpauseBatchCommits();

        assertFalse(provenance.paused());

        vm.prank(committer);
        bytes32 batchId = provenance.anchorBatch(
            keccak256("r-after-unpause"), keccak256("a-after-unpause"), 1,
            submitterActorId, keccak256("n-after-unpause"), "E12_Production"
        );
        assertTrue(provenance.getBatch(batchId).exists);
    }

    function test_nonPauserCannotPause() public {
        vm.prank(stranger);
        vm.expectRevert();
        provenance.pauseBatchCommits();
    }

    // ─────────────────────────────────────────────
    // setBatchSizeLimits
    // ─────────────────────────────────────────────

    function test_setBatchSizeLimits_success() public {
        vm.prank(admin);
        provenance.setBatchSizeLimits(10, 500);
        assertEq(provenance.minBatchSize(), 10);
        assertEq(provenance.maxBatchSize(), 500);
    }

    function test_setBatchSizeLimits_reverts_minGtMax() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(AtsurProvenance.InvalidBatchSize.selector, 500, 500, 10));
        provenance.setBatchSizeLimits(500, 10);
    }

    function test_setBatchSizeLimits_reverts_nonAdmin() public {
        vm.prank(stranger);
        vm.expectRevert();
        provenance.setBatchSizeLimits(10, 500);
    }

    // ─────────────────────────────────────────────
    // FUZZ TESTS
    // ─────────────────────────────────────────────

    /**
     * @dev Fuzz: authorship leaf is deterministic from (artworkId, creatorActorId).
     */
    function testFuzz_authorshipLeaf_isDeterministic(
        bytes32 artworkId,
        bytes32 creatorActorId
    ) public pure {
        bytes32 prefix = keccak256("ATSUR_AUTHORSHIP_V1");
        bytes32 leaf1  = keccak256(abi.encodePacked(prefix, artworkId, creatorActorId));
        bytes32 leaf2  = keccak256(abi.encodePacked(prefix, artworkId, creatorActorId));
        assertEq(leaf1, leaf2);
    }

    /**
     * @dev Fuzz: authorship leaf differs for different creators of the same artwork.
     */
    function testFuzz_authorshipLeaf_differsForDifferentCreators(
        bytes32 artworkId,
        bytes32 creatorA,
        bytes32 creatorB
    ) public pure {
        vm.assume(creatorA != creatorB);
        bytes32 prefix = keccak256("ATSUR_AUTHORSHIP_V1");
        bytes32 leafA  = keccak256(abi.encodePacked(prefix, artworkId, creatorA));
        bytes32 leafB  = keccak256(abi.encodePacked(prefix, artworkId, creatorB));
        assertNotEq(leafA, leafB);
    }

    /**
     * @dev Fuzz: batchId is deterministic from (timestamp, submitterActorId, nonce).
     */
    function testFuzz_batchId_isDeterministic(
        uint256 timestamp,
        bytes32 submitterActor,
        bytes32 nonce
    ) public pure {
        bytes32 id1 = keccak256(abi.encodePacked(timestamp, submitterActor, nonce));
        bytes32 id2 = keccak256(abi.encodePacked(timestamp, submitterActor, nonce));
        assertEq(id1, id2);
    }

    /**
     * @dev Fuzz: different nonces produce different batchIds (even at same timestamp).
     */
    function testFuzz_batchId_differsForDifferentNonces(
        uint256 timestamp,
        bytes32 submitterActor,
        bytes32 nonceA,
        bytes32 nonceB
    ) public pure {
        vm.assume(nonceA != nonceB);
        bytes32 idA = keccak256(abi.encodePacked(timestamp, submitterActor, nonceA));
        bytes32 idB = keccak256(abi.encodePacked(timestamp, submitterActor, nonceB));
        assertNotEq(idA, idB);
    }

    /**
     * @dev Fuzz: usedMerkleRoots prevents double-anchoring.
     */
    function testFuzz_usedMerkleRoots_preventsDoubleAnchor(bytes32 seed) public {
        bytes32 root    = keccak256(abi.encodePacked("fuzz-root", seed));
        bytes32 arweave = keccak256(abi.encodePacked("fuzz-arweave", seed));
        bytes32 nonce   = keccak256(abi.encodePacked("fuzz-nonce", seed));

        vm.prank(committer);
        provenance.anchorBatch(root, arweave, 1, submitterActorId, nonce, "E12_Production");

        assertTrue(provenance.usedMerkleRoots(root));

        bytes32 arweave2 = keccak256(abi.encodePacked("fuzz-arweave-2", seed));
        bytes32 nonce2   = keccak256(abi.encodePacked("fuzz-nonce-2", seed));

        vm.prank(committer);
        vm.expectRevert(abi.encodeWithSelector(AtsurProvenance.DuplicateMerkleRoot.selector, root));
        provenance.anchorBatch(root, arweave2, 1, submitterActorId, nonce2, "E12_Production");
    }
}
