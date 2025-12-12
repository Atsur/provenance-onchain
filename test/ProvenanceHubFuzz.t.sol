// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Test, console} from "forge-std/Test.sol";
import {ProvenanceHub} from "../contracts/ProvenanceHub.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

contract ProvenanceHubFuzzTest is Test {
    ProvenanceHub public hub;
    address public admin = address(0x1);
    address public committer = address(0x2);

    uint256 public constant MIN_BATCH_SIZE = 100;
    uint256 public constant MAX_BATCH_SIZE = 1000;

    function setUp() public {
        ProvenanceHub implementation = new ProvenanceHub();
        bytes memory initData = abi.encodeWithSelector(
            ProvenanceHub.initialize.selector,
            admin,
            MIN_BATCH_SIZE,
            MAX_BATCH_SIZE
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        hub = ProvenanceHub(payable(address(proxy)));

        vm.prank(admin);
        hub.grantRole(hub.BATCH_COMMITTER_ROLE(), committer);
    }

    function testFuzz_CommitBatch_ValidSizes(
        bytes32 merkleRoot,
        bytes32 arweaveTxId,
        uint256 eventCount
    ) public {
        // Bound event count to valid range
        eventCount = bound(eventCount, MIN_BATCH_SIZE, MAX_BATCH_SIZE);

        // Ensure Arweave TX ID is not zero
        vm.assume(arweaveTxId != bytes32(0));
        vm.assume(_hasEntropy(arweaveTxId));

        // Ensure Merkle root is not zero
        vm.assume(merkleRoot != bytes32(0));

        vm.prank(committer);
        hub.commitBatch(merkleRoot, arweaveTxId, eventCount);

        assertEq(hub.batchCount(), 1);
        assertTrue(hub.usedMerkleRoots(merkleRoot));
        assertTrue(hub.usedArweaveTxIds(arweaveTxId));
    }

    function testFuzz_CommitBatch_InvalidSizes(
        bytes32 merkleRoot,
        bytes32 arweaveTxId,
        uint256 eventCount
    ) public {
        // Bound to invalid ranges
        vm.assume(eventCount < MIN_BATCH_SIZE || eventCount > MAX_BATCH_SIZE);
        vm.assume(arweaveTxId != bytes32(0));
        vm.assume(merkleRoot != bytes32(0));

        vm.prank(committer);
        vm.expectRevert();
        hub.commitBatch(merkleRoot, arweaveTxId, eventCount);
    }

    function testFuzz_VerifyProof(
        bytes32[4] memory leaves,
        bytes32 merkleRoot
    ) public {
        // Build simple Merkle tree
        bytes32 leftHash = keccak256(abi.encodePacked(leaves[0], leaves[1]));
        bytes32 rightHash = keccak256(abi.encodePacked(leaves[2], leaves[3]));
        bytes32 calculatedRoot = keccak256(abi.encodePacked(leftHash, rightHash));

        bytes32 arweaveTxId = _generateValidArweaveTxId();

        vm.prank(committer);
        hub.commitBatch(calculatedRoot, arweaveTxId, 4);

        // Create proof for first leaf
        bytes32[] memory proof = new bytes32[](2);
        proof[0] = leaves[1]; // sibling
        proof[1] = rightHash; // uncle

        bool isValid = hub.verifyProofView(0, leaves[0], proof);
        assertTrue(isValid);

        // Invalid proof
        proof[0] = keccak256("wrong");
        isValid = hub.verifyProofView(0, leaves[0], proof);
        assertFalse(isValid);
    }

    function testFuzz_MultipleBatches(
        bytes32[10] memory merkleRoots,
        bytes32[10] memory arweaveTxIds,
        uint256[10] memory eventCounts
    ) public {
        vm.startPrank(committer);

        for (uint256 i = 0; i < 10; i++) {
            // Bound to valid ranges
            eventCounts[i] = bound(eventCounts[i], MIN_BATCH_SIZE, MAX_BATCH_SIZE);
            vm.assume(merkleRoots[i] != bytes32(0));
            vm.assume(arweaveTxIds[i] != bytes32(0));
            vm.assume(_hasEntropy(arweaveTxIds[i]));

            // Ensure unique roots and TX IDs
            for (uint256 j = 0; j < i; j++) {
                vm.assume(merkleRoots[i] != merkleRoots[j]);
                vm.assume(arweaveTxIds[i] != arweaveTxIds[j]);
            }

            hub.commitBatch(merkleRoots[i], arweaveTxIds[i], eventCounts[i]);
        }

        vm.stopPrank();

        assertEq(hub.batchCount(), 10);
    }

    function testFuzz_SetBatchSizeLimits(
        uint256 newMin,
        uint256 newMax
    ) public {
        // Bound to reasonable values
        newMin = bound(newMin, 1, 10000);
        newMax = bound(newMax, 1, 10000);

        vm.assume(newMin <= newMax);
        vm.assume(newMin > 0);
        vm.assume(newMax > 0);

        vm.prank(admin);
        hub.setBatchSizeLimits(newMin, newMax);

        assertEq(hub.minBatchSize(), newMin);
        assertEq(hub.maxBatchSize(), newMax);
    }

    // ============ Helper Functions ============

    function _hasEntropy(bytes32 value) internal pure returns (bool) {
        // Check if value has reasonable entropy (not all same byte)
        uint8 firstByte = uint8(value[0]);
        for (uint256 i = 1; i < 32; i++) {
            if (uint8(value[i]) != firstByte) {
                return true;
            }
        }
        return firstByte == 0; // All zeros is also invalid
    }

    function _generateValidArweaveTxId() internal view returns (bytes32) {
        return keccak256(abi.encodePacked(block.timestamp, block.prevrandao, msg.sender));
    }
}

