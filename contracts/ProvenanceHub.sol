// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";

/**
 * @title ProvenanceHub
 * @notice AtsurProvenance-compatible: Merkle-batch provenance anchoring with full data on Arweave. Public verification and Phase 1 authorship check.
 * @dev Uses Merkle trees to store only roots on-chain; batch payload stored on Arweave. UUPS upgradeable, role-based access, pause.
 */
contract ProvenanceHub is
    UUPSUpgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable
{
    using MerkleProof for bytes32[];

    // ============ Constants ============

    /// @notice Role for committing batches
    bytes32 public constant BATCH_COMMITTER_ROLE = keccak256("BATCH_COMMITTER_ROLE");

    /// @notice Role for pausing contract operations
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    /// @notice Minimum batch size (configurable)
    uint256 public minBatchSize;

    /// @notice Maximum batch size (configurable)
    uint256 public maxBatchSize;

    /// @notice Arweave transaction ID length (43 characters base64url encoded)
    uint256 private constant ARWEAVE_TX_ID_LENGTH = 43;

    // ============ Reentrancy Guard ============
    
    /// @notice Reentrancy guard status
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;
    uint256 private _status;

    // ============ Storage ============

    /// @notice Batch commit structure - minimal on-chain data (AtsurProvenance-compatible)
    struct BatchCommit {
        bytes32 merkleRoot;        // Merkle root of all events in batch
        bytes32 arweaveTxId;       // Arweave transaction ID (primary archive reference)
        uint256 timestamp;         // Block timestamp when committed (anchoredAt)
        uint256 eventCount;        // Number of events in batch
        uint256 blockNumber;       // Block number when committed
        string eventType;          // Primary CIDOC class in this batch (e.g. E12_Production)
    }

    /// @notice Mapping of batch ID to BatchCommit
    mapping(uint256 => BatchCommit) public batches;

    /// @notice Total number of batches committed
    uint256 public batchCount;

    /// @notice Mapping to check if a Merkle root has been used (prevents duplicates)
    mapping(bytes32 => bool) public usedMerkleRoots;

    /// @notice Mapping to check if an Arweave TX ID has been used (prevents duplicates)
    mapping(bytes32 => bool) public usedArweaveTxIds;

    // ============ Events ============

    /// @notice Emitted when a new batch is committed (legacy)
    event BatchCommitted(
        uint256 indexed batchId,
        bytes32 indexed merkleRoot,
        bytes32 indexed arweaveTxId,
        uint256 eventCount,
        uint256 timestamp,
        address committer
    );

    /// @notice Emitted when a new batch is anchored (AtsurProvenance-compatible; use for indexers)
    event BatchAnchored(
        uint256 indexed batchIndex,
        bytes32 merkleRoot,
        bytes32 arweaveTxId,
        uint256 eventCount
    );

    /// @notice Emitted when batch size limits are updated
    event BatchSizeLimitsUpdated(uint256 minBatchSize, uint256 maxBatchSize);

    /// @notice Emitted when a Merkle proof is verified
    event ProofVerified(
        uint256 indexed batchId,
        bytes32 indexed leafHash,
        bool verified
    );

    // ============ Errors ============

    error InvalidBatchSize(uint256 eventCount, uint256 minSize, uint256 maxSize);
    error InvalidArweaveTxId(bytes32 txId);
    error DuplicateMerkleRoot(bytes32 merkleRoot);
    error DuplicateArweaveTxId(bytes32 arweaveTxId);
    error InvalidProof();
    error BatchNotFound(uint256 batchId);
    error ZeroAddress();
    error EmptyEventType();

    // ============ Modifiers ============

    /// @notice Validates Arweave transaction ID format
    /// @dev Arweave TX IDs are 43 characters base64url encoded (256 bits = 32 bytes)
    modifier validArweaveTxId(bytes32 arweaveTxId) {
        // Check that TX ID is not zero (basic validation)
        // Full format validation happens in _validateArweaveTxId
        if (arweaveTxId == bytes32(0)) {
            revert InvalidArweaveTxId(arweaveTxId);
        }
        _;
    }

    // ============ Initialization ============

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the contract
    /// @param admin Address to grant DEFAULT_ADMIN_ROLE
    /// @param initialMinBatchSize Minimum events per batch
    /// @param initialMaxBatchSize Maximum events per batch
    function initialize(
        address admin,
        uint256 initialMinBatchSize,
        uint256 initialMaxBatchSize
    ) public initializer {
        if (admin == address(0)) {
            revert ZeroAddress();
        }

        __AccessControl_init();
        __Pausable_init();
        _status = _NOT_ENTERED;

        // Grant admin role to deployer
        _grantRole(DEFAULT_ADMIN_ROLE, admin);

        // Validate and set initial batch size limits
        if (initialMinBatchSize == 0 || initialMaxBatchSize == 0) {
            revert InvalidBatchSize(initialMinBatchSize, initialMinBatchSize, initialMaxBatchSize);
        }
        if (initialMinBatchSize > initialMaxBatchSize) {
            revert InvalidBatchSize(initialMinBatchSize, initialMinBatchSize, initialMaxBatchSize);
        }

        minBatchSize = initialMinBatchSize;
        maxBatchSize = initialMaxBatchSize;

        emit BatchSizeLimitsUpdated(initialMinBatchSize, initialMaxBatchSize);
    }

    // ============ Batch Committing ============

    /// @notice Anchors a batch of provenance events (AtsurProvenance-compatible)
    /// @param merkleRoot Merkle root of all events in the batch
    /// @param arweaveTxId Arweave transaction ID where full batch payload is stored
    /// @param eventCount Number of events in the batch
    /// @param eventType Primary CIDOC class for this batch (e.g. "E12_Production", "E8_Acquisition")
    /// @dev Only callable by BATCH_COMMITTER_ROLE when not paused. Emits BatchAnchored for indexers.
    function anchorBatch(
        bytes32 merkleRoot,
        bytes32 arweaveTxId,
        uint256 eventCount,
        string calldata eventType
    )
        external
        onlyRole(BATCH_COMMITTER_ROLE)
        whenNotPaused
        validArweaveTxId(arweaveTxId)
    {
        if (bytes(eventType).length == 0) {
            revert EmptyEventType();
        }
        _commitBatch(merkleRoot, arweaveTxId, eventCount, eventType);
    }

    /// @notice Commits a batch of provenance events (legacy; defaults to E12_Production)
    /// @param merkleRoot Merkle root of all events in the batch
    /// @param arweaveTxId Arweave transaction ID where full data is stored
    /// @param eventCount Number of events in the batch
    /// @dev Prefer anchorBatch with explicit eventType for new integrations.
    function commitBatch(
        bytes32 merkleRoot,
        bytes32 arweaveTxId,
        uint256 eventCount
    )
        external
        onlyRole(BATCH_COMMITTER_ROLE)
        whenNotPaused
        validArweaveTxId(arweaveTxId)
    {
        _commitBatch(merkleRoot, arweaveTxId, eventCount, "E12_Production");
    }

    /// @dev Internal batch commit logic; writes storage and emits both BatchAnchored and BatchCommitted.
    function _commitBatch(
        bytes32 merkleRoot,
        bytes32 arweaveTxId,
        uint256 eventCount,
        string memory eventType
    ) internal {
        require(_status != _ENTERED, "ReentrancyGuard: reentrant call");
        _status = _ENTERED;

        if (eventCount < minBatchSize || eventCount > maxBatchSize) {
            revert InvalidBatchSize(eventCount, minBatchSize, maxBatchSize);
        }
        _validateArweaveTxId(arweaveTxId);
        if (usedMerkleRoots[merkleRoot]) {
            revert DuplicateMerkleRoot(merkleRoot);
        }
        if (usedArweaveTxIds[arweaveTxId]) {
            revert DuplicateArweaveTxId(arweaveTxId);
        }

        uint256 currentBatchId = batchCount;
        batches[currentBatchId] = BatchCommit({
            merkleRoot: merkleRoot,
            arweaveTxId: arweaveTxId,
            timestamp: block.timestamp,
            eventCount: eventCount,
            blockNumber: block.number,
            eventType: eventType
        });

        usedMerkleRoots[merkleRoot] = true;
        usedArweaveTxIds[arweaveTxId] = true;
        batchCount++;

        emit BatchAnchored(currentBatchId, merkleRoot, arweaveTxId, eventCount);
        emit BatchCommitted(
            currentBatchId,
            merkleRoot,
            arweaveTxId,
            eventCount,
            block.timestamp,
            msg.sender
        );

        _status = _NOT_ENTERED;
    }

    // ============ Proof Verification ============

    /// @notice Verifies a Merkle proof for a specific event
    /// @param batchId ID of the batch containing the event
    /// @param leafHash Hash of the event (leaf in Merkle tree)
    /// @param proof Merkle proof path from leaf to root
    /// @return true if proof is valid, false otherwise
    /// @dev This function emits an event, so it's not view
    function verifyProof(
        uint256 batchId,
        bytes32 leafHash,
        bytes32[] memory proof
    ) external whenNotPaused returns (bool) {
        if (batchId >= batchCount) {
            revert BatchNotFound(batchId);
        }

        BatchCommit memory batch = batches[batchId];
        bool isValid = proof.verify(batch.merkleRoot, leafHash);

        emit ProofVerified(batchId, leafHash, isValid);

        return isValid;
    }

    /// @notice Verifies a Merkle proof (view function, no event emission)
    /// @param batchId ID of the batch containing the event
    /// @param leafHash Hash of the event (leaf in Merkle tree)
    /// @param proof Merkle proof path from leaf to root
    /// @return true if proof is valid, false otherwise
    function verifyProofView(
        uint256 batchId,
        bytes32 leafHash,
        bytes32[] memory proof
    ) external view returns (bool) {
        if (batchId >= batchCount) {
            revert BatchNotFound(batchId);
        }

        BatchCommit memory batch = batches[batchId];
        return proof.verify(batch.merkleRoot, leafHash);
    }

    /// @notice Verifies that a leaf is included in an anchored batch (AtsurProvenance-compatible)
    /// @param batchIndex Batch to verify against
    /// @param leaf Computed leaf hash for the CIDOC event
    /// @param proofPath Sibling hashes from leaf to root (sorted order; use calldata for gas)
    /// @return true if the leaf is proven in this batch
    function verifyProvenanceEvent(
        uint256 batchIndex,
        bytes32 leaf,
        bytes32[] calldata proofPath
    ) external view returns (bool) {
        if (batchIndex >= batchCount) {
            revert BatchNotFound(batchIndex);
        }
        bytes32 root = batches[batchIndex].merkleRoot;
        bytes32 computed = leaf;
        for (uint256 i = 0; i < proofPath.length; i++) {
            bytes32 sibling = proofPath[i];
            computed = computed < sibling
                ? keccak256(abi.encodePacked(computed, sibling))
                : keccak256(abi.encodePacked(sibling, computed));
        }
        return computed == root;
    }

    // ============ Phase 1 Authorship (AtsurProvenance-compatible) ============

    /// @notice Checks authorship commitment (Phase 1: commitment == presented; Phase 2 can delegate to ZK verifier)
    /// @param artworkId Artwork identifier (for future ZK public input; unused in Phase 1)
    /// @param commitment The authorship commitment stored on-chain for this artwork
    /// @param presented The value presented by the prover (recomputed commitment or ZK proof output)
    /// @return true if commitment matches presented
    function checkAuthorship(
        bytes32 artworkId,
        bytes32 commitment,
        bytes32 presented
    ) external pure returns (bool) {
        artworkId; // silence unused parameter; used in Phase 2 ZK public inputs
        return commitment == presented;
    }

    // ============ Batch Information ============

    /// @notice Gets batch information
    /// @param batchId ID of the batch
    /// @return BatchCommit struct with batch details
    function getBatch(uint256 batchId) external view returns (BatchCommit memory) {
        if (batchId >= batchCount) {
            revert BatchNotFound(batchId);
        }
        return batches[batchId];
    }

    /// @notice Gets the latest batch ID
    /// @return Latest batch ID (batchCount - 1)
    function getLatestBatchId() external view returns (uint256) {
        if (batchCount == 0) {
            revert BatchNotFound(0);
        }
        return batchCount - 1;
    }

    // ============ Configuration ============

    /// @notice Updates batch size limits
    /// @param newMinBatchSize New minimum batch size
    /// @param newMaxBatchSize New maximum batch size
    /// @dev Only callable by DEFAULT_ADMIN_ROLE
    function setBatchSizeLimits(
        uint256 newMinBatchSize,
        uint256 newMaxBatchSize
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newMinBatchSize == 0 || newMaxBatchSize == 0) {
            revert InvalidBatchSize(newMinBatchSize, newMinBatchSize, newMaxBatchSize);
        }
        if (newMinBatchSize > newMaxBatchSize) {
            revert InvalidBatchSize(newMinBatchSize, newMinBatchSize, newMaxBatchSize);
        }

        minBatchSize = newMinBatchSize;
        maxBatchSize = newMaxBatchSize;

        emit BatchSizeLimitsUpdated(newMinBatchSize, newMaxBatchSize);
    }

    // ============ Pause Functionality ============

    /// @notice Pauses batch commits (proof verification still works)
    /// @dev Only callable by PAUSER_ROLE
    function pauseBatchCommits() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /// @notice Unpauses batch commits
    /// @dev Only callable by PAUSER_ROLE
    function unpauseBatchCommits() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    // ============ Internal Functions ============

    /// @notice Validates Arweave transaction ID format
    /// @dev Arweave TX IDs are base64url encoded 43-character strings
    /// @dev We store as bytes32, so we validate it's not all zeros and has reasonable entropy
    /// @param arweaveTxId The Arweave transaction ID to validate
    function _validateArweaveTxId(bytes32 arweaveTxId) internal pure {
        // Basic validation: ensure not zero
        if (arweaveTxId == bytes32(0)) {
            revert InvalidArweaveTxId(arweaveTxId);
        }

        // Additional validation: check for reasonable entropy
        // Arweave TX IDs should have high entropy (not all same byte)
        uint8 firstByte = uint8(arweaveTxId[0]);
        bool allSame = true;
        for (uint256 i = 1; i < 32; i++) {
            if (uint8(arweaveTxId[i]) != firstByte) {
                allSame = false;
                break;
            }
        }
        if (allSame && firstByte != 0) {
            revert InvalidArweaveTxId(arweaveTxId);
        }
    }

    /// @notice Authorizes contract upgrades
    /// @dev Only DEFAULT_ADMIN_ROLE can authorize upgrades
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    // ============ View Functions ============

    /// @notice Returns the current implementation address
    /// @return Address of the implementation contract
    function getImplementation() external view returns (address) {
        return ERC1967Utils.getImplementation();
    }

    /// @notice Returns contract version (Atsur 1.0–compatible)
    /// @return Version string
    function version() external pure returns (string memory) {
        return "1.1.0";
    }
}

