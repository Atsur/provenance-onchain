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

    event BatchAnchored(
        uint256 indexed batchIndex,
        bytes32 merkleRoot,
        bytes32 arweaveTxId,
        uint256 eventCount
    );

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

    function test_Initialization() public view {
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
        (bytes32 root, bytes32 txId, , uint256 count, , ) = _getBatch(0);
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
        vm.expectRevert(abi.encodeWithSelector(ProvenanceHub.InvalidArweaveTxId.selector, bytes32(0)));
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

    function test_AnchorBatch_Success() public {
        bytes32 merkleRoot = keccak256("anchor root");
        bytes32 arweaveTxId = generateValidArweaveTxId();
        string memory eventType = "E8_Acquisition";
        vm.prank(committer);
        vm.expectEmit(true, true, true, true);
        emit BatchAnchored(0, merkleRoot, arweaveTxId, 500);
        hub.anchorBatch(merkleRoot, arweaveTxId, 500, eventType);
        assertEq(hub.batchCount(), 1);
        assertEq(hub.getBatch(0).eventType, eventType);
    }

    function test_AnchorBatch_EmptyEventType() public {
        vm.prank(committer);
        vm.expectRevert(ProvenanceHub.EmptyEventType.selector);
        hub.anchorBatch(keccak256("r"), generateValidArweaveTxId(), 500, "");
    }

    // ============ Proof Verification Tests ============

    function test_VerifyProof_Success() public {
        // Create a simple 4-leaf Merkle tree for testing
        // We'll use a smaller batch by temporarily adjusting limits
        vm.startPrank(admin);
        hub.setBatchSizeLimits(4, 1000);
        vm.stopPrank();

        // Create test leaves
        string[] memory events = new string[](4);
        events[0] = "event0";
        events[1] = "event1";
        events[2] = "event2";
        events[3] = "event3";

        // Generate Merkle tree using merkletreejs via FFI
        (bytes32 root, bytes32[] memory leaves, bytes32[][] memory proofs) = generateMerkleTreeFFI(events);

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

        // Restore original limits
        vm.prank(admin);
        hub.setBatchSizeLimits(MIN_BATCH_SIZE, MAX_BATCH_SIZE);
    }

    function generateMerkleTreeFFI(string[] memory events) internal pure returns (bytes32 root, bytes32[] memory leaves, bytes32[][] memory proofs) {
        // Use pre-computed values from merkletreejs (generated with sortPairs: true)
        // These match OpenZeppelin's commutativeKeccak256 format
        require(events.length == 4, "Expected 4 events");
        
        leaves = new bytes32[](4);
        leaves[0] = 0xf80c12fc0fc0cdcc60acaf7851f7f7b37808eba9939a24e357314e54210b5618; // keccak256("event0")
        leaves[1] = 0x628f846d1b696a65208be38a0fc7a66447d7b560c9eaf6ae6528dff13ded62c9; // keccak256("event1")
        leaves[2] = 0xca4b9cef571f3094bd68517ba981cf3d4a3d2918e153773fd22ec1332320cf5b; // keccak256("event2")
        leaves[3] = 0xbd67f03d8382a9e66f69269965d06c80a8b097940554b8ee764423a2dcf8bb24; // keccak256("event3")
        
        root = 0x262038f4cc4d07d107fff511aa3354e0b5b1b1235b8eb0df0f3eec860ef6bd85;
        
        proofs = new bytes32[][](4);
        proofs[0] = new bytes32[](2);
        proofs[0][0] = 0x628f846d1b696a65208be38a0fc7a66447d7b560c9eaf6ae6528dff13ded62c9;
        proofs[0][1] = 0x99baab6b3f2783959c52ccfbdee9d7a5c9a8aad304116fd516488e7e113d0fb7;
        
        proofs[1] = new bytes32[](2);
        proofs[1][0] = 0xf80c12fc0fc0cdcc60acaf7851f7f7b37808eba9939a24e357314e54210b5618;
        proofs[1][1] = 0x99baab6b3f2783959c52ccfbdee9d7a5c9a8aad304116fd516488e7e113d0fb7;
        
        proofs[2] = new bytes32[](2);
        proofs[2][0] = 0xbd67f03d8382a9e66f69269965d06c80a8b097940554b8ee764423a2dcf8bb24;
        proofs[2][1] = 0x723d8d2621afc223685c461c99efa818b250de12ed45de9c8726822443dcb9a2;
        
        proofs[3] = new bytes32[](2);
        proofs[3][0] = 0xca4b9cef571f3094bd68517ba981cf3d4a3d2918e153773fd22ec1332320cf5b;
        proofs[3][1] = 0x723d8d2621afc223685c461c99efa818b250de12ed45de9c8726822443dcb9a2;
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

    function test_VerifyProvenanceEvent_Success() public {
        vm.startPrank(admin);
        hub.setBatchSizeLimits(4, 1000);
        vm.stopPrank();
        string[] memory events = new string[](4);
        events[0] = "event0";
        events[1] = "event1";
        events[2] = "event2";
        events[3] = "event3";
        (bytes32 root, bytes32[] memory leaves, bytes32[][] memory proofs) = generateMerkleTreeFFI(events);
        bytes32 arweaveTxId = generateValidArweaveTxId();
        vm.prank(committer);
        hub.anchorBatch(root, arweaveTxId, 4, "E12_Production");
        assertTrue(hub.verifyProvenanceEvent(0, leaves[0], proofs[0]));
        assertTrue(hub.verifyProvenanceEvent(0, leaves[3], proofs[3]));
        vm.prank(admin);
        hub.setBatchSizeLimits(MIN_BATCH_SIZE, MAX_BATCH_SIZE);
    }

    function test_VerifyProvenanceEvent_InvalidProof() public {
        bytes32 arweaveTxId = generateValidArweaveTxId();
        vm.prank(committer);
        hub.commitBatch(keccak256("root"), arweaveTxId, 100);
        bytes32[] memory badProof = new bytes32[](1);
        badProof[0] = keccak256("wrong");
        assertFalse(hub.verifyProvenanceEvent(0, keccak256("wrong leaf"), badProof));
    }

    function test_VerifyProvenanceEvent_BatchNotFound() public {
        bytes32[] memory proof = new bytes32[](0);
        vm.expectRevert(abi.encodeWithSelector(ProvenanceHub.BatchNotFound.selector, 999));
        hub.verifyProvenanceEvent(999, keccak256("leaf"), proof);
    }

    function test_CheckAuthorship_Match() public view {
        bytes32 c = keccak256("commitment");
        assertTrue(hub.checkAuthorship(keccak256("id"), c, c));
    }

    function test_CheckAuthorship_NoMatch() public view {
        assertFalse(hub.checkAuthorship(keccak256("id"), keccak256("c"), keccak256("d")));
    }

    function test_Version() public view {
        assertEq(hub.version(), "1.1.0");
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
        assertEq(batch.eventType, "E12_Production");
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
        uint256 blockNumber,
        string memory eventType
    ) {
        ProvenanceHub.BatchCommit memory batch = hub.getBatch(batchId);
        return (batch.merkleRoot, batch.arweaveTxId, batch.timestamp, batch.eventCount, batch.blockNumber, batch.eventType);
    }
}

