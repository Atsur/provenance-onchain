// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Test, console} from "forge-std/Test.sol";
import {ProvenanceHub} from "../contracts/ProvenanceHub.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

contract ProvenanceHubTest is Test {
    ProvenanceHub public hub;
    ProvenanceHub public implementation;
    ERC1967Proxy public proxy;

    address public admin = address(0x1);
    address public committer = address(0x2);
    address public pauser = address(0x3);
    address public user = address(0x4);

    uint256 public constant MIN_BATCH_SIZE = 100;
    uint256 public constant MAX_BATCH_SIZE = 1000;

    event BatchCommitted(
        uint256 indexed batchId,
        bytes32 indexed merkleRoot,
        bytes32 indexed arweaveTxId,
        uint256 eventCount,
        uint256 timestamp,
        address committer
    );

    event BatchSizeLimitsUpdated(uint256 minBatchSize, uint256 maxBatchSize);

    function setUp() public {
        // Deploy implementation
        implementation = new ProvenanceHub();

        // Encode initialization data
        bytes memory initData = abi.encodeWithSelector(
            ProvenanceHub.initialize.selector,
            admin,
            MIN_BATCH_SIZE,
            MAX_BATCH_SIZE
        );

        // Deploy proxy
        proxy = new ERC1967Proxy(address(implementation), initData);

        // Get hub instance
        hub = ProvenanceHub(payable(address(proxy)));

        // Setup roles
        vm.startPrank(admin);
        hub.grantRole(hub.BATCH_COMMITTER_ROLE(), committer);
        hub.grantRole(hub.PAUSER_ROLE(), pauser);
        vm.stopPrank();
    }

    // ============ Helper Functions ============

    function generateMerkleTree(bytes32[] memory leaves) internal pure returns (bytes32 root, bytes32[][] memory proofs) {
        require(leaves.length > 0, "Empty leaves array");

        // Build tree bottom-up
        bytes32[] memory currentLevel = leaves;
        uint256 levelSize = leaves.length;
        bytes32[][] memory allProofs = new bytes32[][](leaves.length);

        // Calculate tree height
        uint256 height = 0;
        uint256 temp = levelSize;
        while (temp > 1) {
            temp = (temp + 1) / 2;
            height++;
        }

        // Build proofs for each leaf
        for (uint256 i = 0; i < leaves.length; i++) {
            bytes32[] memory proof = new bytes32[](height);
            uint256 proofIndex = 0;
            uint256 index = i;
            bytes32[] memory tempLevel = new bytes32[](levelSize);
            for (uint256 j = 0; j < levelSize; j++) {
                tempLevel[j] = currentLevel[j];
            }

            uint256 currentLevelSize = levelSize;
            for (uint256 level = 0; level < height; level++) {
                if (currentLevelSize == 1) break;

                bool isLeft = index % 2 == 0;
                uint256 siblingIndex = isLeft ? index + 1 : index - 1;

                if (siblingIndex < currentLevelSize) {
                    proof[proofIndex] = tempLevel[siblingIndex];
                } else {
                    // Odd number of nodes, duplicate last node
                    proof[proofIndex] = tempLevel[currentLevelSize - 1];
                }

                proofIndex++;
                index = index / 2;
                currentLevelSize = (currentLevelSize + 1) / 2;

                // Build next level
                bytes32[] memory nextLevel = new bytes32[](currentLevelSize);
                for (uint256 j = 0; j < currentLevelSize; j++) {
                    uint256 leftIndex = j * 2;
                    uint256 rightIndex = j * 2 + 1;
                    if (rightIndex < tempLevel.length) {
                        nextLevel[j] = keccak256(abi.encodePacked(tempLevel[leftIndex], tempLevel[rightIndex]));
                    } else {
                        nextLevel[j] = tempLevel[leftIndex];
                    }
                }
                tempLevel = nextLevel;
            }

            allProofs[i] = proof;
        }

        // Build root
        while (currentLevel.length > 1) {
            bytes32[] memory nextLevel = new bytes32[]((currentLevel.length + 1) / 2);
            for (uint256 i = 0; i < nextLevel.length; i++) {
                uint256 leftIndex = i * 2;
                uint256 rightIndex = i * 2 + 1;
                if (rightIndex < currentLevel.length) {
                    nextLevel[i] = keccak256(abi.encodePacked(currentLevel[leftIndex], currentLevel[rightIndex]));
                } else {
                    nextLevel[i] = currentLevel[leftIndex];
                }
            }
            currentLevel = nextLevel;
        }

        root = currentLevel[0];
        proofs = allProofs;
    }

    function generateValidArweaveTxId() internal view returns (bytes32) {
        // Generate a random bytes32 that simulates a valid Arweave TX ID
        // In reality, Arweave TX IDs are base64url encoded, but we store as bytes32
        return keccak256(abi.encodePacked(block.timestamp, block.prevrandao, msg.sender));
    }

    // ============ Initialization Tests ============

    function test_Initialization() public {
        assertEq(hub.minBatchSize(), MIN_BATCH_SIZE);
        assertEq(hub.maxBatchSize(), MAX_BATCH_SIZE);
        assertTrue(hub.hasRole(hub.DEFAULT_ADMIN_ROLE(), admin));
        assertFalse(hub.paused());
    }

    function test_Initialization_ZeroAdmin() public {
        ProvenanceHub newImpl = new ProvenanceHub();
        bytes memory initData = abi.encodeWithSelector(
            ProvenanceHub.initialize.selector,
            address(0),
            MIN_BATCH_SIZE,
            MAX_BATCH_SIZE
        );

        vm.expectRevert(ProvenanceHub.ZeroAddress.selector);
        new ERC1967Proxy(address(newImpl), initData);
    }

    function test_Initialization_InvalidBatchSizes() public {
        ProvenanceHub newImpl = new ProvenanceHub();
        bytes memory initData = abi.encodeWithSelector(
            ProvenanceHub.initialize.selector,
            admin,
            1000, // min > max
            100
        );

        vm.expectRevert();
        new ERC1967Proxy(address(newImpl), initData);
    }

    // ============ Batch Committing Tests ============

    function test_CommitBatch_Success() public {
        bytes32 merkleRoot = keccak256("test root");
        bytes32 arweaveTxId = generateValidArweaveTxId();
        uint256 eventCount = 500;

        vm.prank(committer);
        vm.expectEmit(true, true, true, true);
        emit BatchCommitted(0, merkleRoot, arweaveTxId, eventCount, block.timestamp, committer);

        hub.commitBatch(merkleRoot, arweaveTxId, eventCount);

        assertEq(hub.batchCount(), 1);
        (bytes32 root, bytes32 txId, uint256 timestamp, uint256 count, uint256 blockNum) = _getBatch(0);
        assertEq(root, merkleRoot);
        assertEq(txId, arweaveTxId);
        assertEq(count, eventCount);
        assertTrue(hub.usedMerkleRoots(merkleRoot));
        assertTrue(hub.usedArweaveTxIds(arweaveTxId));
    }

    function test_CommitBatch_Unauthorized() public {
        bytes32 merkleRoot = keccak256("test root");
        bytes32 arweaveTxId = generateValidArweaveTxId();

        vm.prank(user);
        vm.expectRevert();
        hub.commitBatch(merkleRoot, arweaveTxId, 500);
    }

    function test_CommitBatch_InvalidBatchSize_TooSmall() public {
        bytes32 merkleRoot = keccak256("test root");
        bytes32 arweaveTxId = generateValidArweaveTxId();

        vm.prank(committer);
        vm.expectRevert(abi.encodeWithSelector(ProvenanceHub.InvalidBatchSize.selector, 50, MIN_BATCH_SIZE, MAX_BATCH_SIZE));
        hub.commitBatch(merkleRoot, arweaveTxId, 50);
    }

    function test_CommitBatch_InvalidBatchSize_TooLarge() public {
        bytes32 merkleRoot = keccak256("test root");
        bytes32 arweaveTxId = generateValidArweaveTxId();

        vm.prank(committer);
        vm.expectRevert(abi.encodeWithSelector(ProvenanceHub.InvalidBatchSize.selector, 2000, MIN_BATCH_SIZE, MAX_BATCH_SIZE));
        hub.commitBatch(merkleRoot, arweaveTxId, 2000);
    }

    function test_CommitBatch_InvalidArweaveTxId_Zero() public {
        bytes32 merkleRoot = keccak256("test root");

        vm.prank(committer);
        vm.expectRevert(ProvenanceHub.InvalidArweaveTxId.selector);
        hub.commitBatch(merkleRoot, bytes32(0), 500);
    }

    function test_CommitBatch_DuplicateMerkleRoot() public {
        bytes32 merkleRoot = keccak256("test root");
        bytes32 arweaveTxId1 = generateValidArweaveTxId();
        bytes32 arweaveTxId2 = generateValidArweaveTxId();

        vm.startPrank(committer);
        hub.commitBatch(merkleRoot, arweaveTxId1, 500);

        vm.expectRevert(abi.encodeWithSelector(ProvenanceHub.DuplicateMerkleRoot.selector, merkleRoot));
        hub.commitBatch(merkleRoot, arweaveTxId2, 600);
        vm.stopPrank();
    }

    function test_CommitBatch_DuplicateArweaveTxId() public {
        bytes32 merkleRoot1 = keccak256("test root 1");
        bytes32 merkleRoot2 = keccak256("test root 2");
        bytes32 arweaveTxId = generateValidArweaveTxId();

        vm.startPrank(committer);
        hub.commitBatch(merkleRoot1, arweaveTxId, 500);

        vm.expectRevert(abi.encodeWithSelector(ProvenanceHub.DuplicateArweaveTxId.selector, arweaveTxId));
        hub.commitBatch(merkleRoot2, arweaveTxId, 600);
        vm.stopPrank();
    }

    function test_CommitBatch_WhenPaused() public {
        bytes32 merkleRoot = keccak256("test root");
        bytes32 arweaveTxId = generateValidArweaveTxId();

        vm.prank(pauser);
        hub.pauseBatchCommits();

        vm.prank(committer);
        vm.expectRevert();
        hub.commitBatch(merkleRoot, arweaveTxId, 500);
    }

    function test_CommitBatch_MultipleBatches() public {
        vm.startPrank(committer);
        for (uint256 i = 0; i < 10; i++) {
            bytes32 merkleRoot = keccak256(abi.encodePacked("root", i));
            bytes32 arweaveTxId = keccak256(abi.encodePacked("arweave", i, block.timestamp));
            hub.commitBatch(merkleRoot, arweaveTxId, 500);
        }
        vm.stopPrank();

        assertEq(hub.batchCount(), 10);
    }

    // ============ Proof Verification Tests ============

    function test_VerifyProof_Success() public {
        // Create test leaves
        bytes32[] memory leaves = new bytes32[](4);
        leaves[0] = keccak256("event1");
        leaves[1] = keccak256("event2");
        leaves[2] = keccak256("event3");
        leaves[3] = keccak256("event4");

        // Generate Merkle tree
        (bytes32 root, bytes32[][] memory proofs) = generateMerkleTree(leaves);

        // Commit batch
        bytes32 arweaveTxId = generateValidArweaveTxId();
        vm.prank(committer);
        hub.commitBatch(root, arweaveTxId, 4);

        // Verify proof for first leaf
        bool isValid = hub.verifyProofView(0, leaves[0], proofs[0]);
        assertTrue(isValid);

        // Verify proof for last leaf
        isValid = hub.verifyProofView(0, leaves[3], proofs[3]);
        assertTrue(isValid);
    }

    function test_VerifyProof_InvalidProof() public {
        bytes32 merkleRoot = keccak256("test root");
        bytes32 arweaveTxId = generateValidArweaveTxId();

        vm.prank(committer);
        hub.commitBatch(merkleRoot, arweaveTxId, 100);

        bytes32[] memory invalidProof = new bytes32[](1);
        invalidProof[0] = keccak256("wrong");

        bool isValid = hub.verifyProofView(0, keccak256("wrong leaf"), invalidProof);
        assertFalse(isValid);
    }

    function test_VerifyProof_BatchNotFound() public {
        bytes32[] memory proof = new bytes32[](0);
        vm.expectRevert(abi.encodeWithSelector(ProvenanceHub.BatchNotFound.selector, 999));
        hub.verifyProofView(999, keccak256("leaf"), proof);
    }

    // ============ Configuration Tests ============

    function test_SetBatchSizeLimits() public {
        vm.prank(admin);
        vm.expectEmit(true, true, false, false);
        emit BatchSizeLimitsUpdated(200, 2000);
        hub.setBatchSizeLimits(200, 2000);

        assertEq(hub.minBatchSize(), 200);
        assertEq(hub.maxBatchSize(), 2000);
    }

    function test_SetBatchSizeLimits_Unauthorized() public {
        vm.prank(user);
        vm.expectRevert();
        hub.setBatchSizeLimits(200, 2000);
    }

    function test_SetBatchSizeLimits_Invalid() public {
        vm.prank(admin);
        vm.expectRevert();
        hub.setBatchSizeLimits(1000, 500); // min > max
    }

    // ============ Pause Tests ============

    function test_Pause_Unpause() public {
        vm.prank(pauser);
        hub.pauseBatchCommits();
        assertTrue(hub.paused());

        vm.prank(pauser);
        hub.unpauseBatchCommits();
        assertFalse(hub.paused());
    }

    function test_Pause_Unauthorized() public {
        vm.prank(user);
        vm.expectRevert();
        hub.pauseBatchCommits();
    }

    function test_VerifyProof_WhenPaused() public {
        bytes32 merkleRoot = keccak256("test root");
        bytes32 arweaveTxId = generateValidArweaveTxId();

        vm.startPrank(committer);
        hub.commitBatch(merkleRoot, arweaveTxId, 100);
        vm.stopPrank();

        vm.prank(pauser);
        hub.pauseBatchCommits();

        // Proof verification should still work when paused
        bytes32[] memory proof = new bytes32[](0);
        bool isValid = hub.verifyProofView(0, keccak256("leaf"), proof);
        // Will be false because proof is invalid, but function should execute
        assertFalse(isValid);
    }

    // ============ View Functions Tests ============

    function test_GetBatch() public {
        bytes32 merkleRoot = keccak256("test root");
        bytes32 arweaveTxId = generateValidArweaveTxId();
        uint256 eventCount = 500;

        vm.prank(committer);
        hub.commitBatch(merkleRoot, arweaveTxId, eventCount);

        ProvenanceHub.BatchCommit memory batch = hub.getBatch(0);
        assertEq(batch.merkleRoot, merkleRoot);
        assertEq(batch.arweaveTxId, arweaveTxId);
        assertEq(batch.eventCount, eventCount);
    }

    function test_GetBatch_NotFound() public {
        vm.expectRevert(abi.encodeWithSelector(ProvenanceHub.BatchNotFound.selector, 0));
        hub.getBatch(0);
    }

    function test_GetLatestBatchId() public {
        vm.startPrank(committer);
        for (uint256 i = 0; i < 5; i++) {
            bytes32 merkleRoot = keccak256(abi.encodePacked("root", i));
            bytes32 arweaveTxId = keccak256(abi.encodePacked("arweave", i));
            hub.commitBatch(merkleRoot, arweaveTxId, 500);
        }
        vm.stopPrank();

        assertEq(hub.getLatestBatchId(), 4);
    }

    // ============ Helper Functions ============

    function _getBatch(uint256 batchId) internal view returns (
        bytes32 merkleRoot,
        bytes32 arweaveTxId,
        uint256 timestamp,
        uint256 eventCount,
        uint256 blockNumber
    ) {
        ProvenanceHub.BatchCommit memory batch = hub.getBatch(batchId);
        return (batch.merkleRoot, batch.arweaveTxId, batch.timestamp, batch.eventCount, batch.blockNumber);
    }
}

