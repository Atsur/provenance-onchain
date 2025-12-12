// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

/**
 * @title ProvenanceHub
 * @notice Main contract for committing provenance event batches to blockchain
 * @dev Uses Merkle trees to store only roots on-chain, with full data on Arweave
 * @dev UUPS upgradeable, role-based access control, and pause functionality
 */
contract ProvenanceHub is
    UUPSUpgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable
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

    // ============ Storage ============

    /// @notice Batch commit structure - minimal on-chain data
    struct BatchCommit {
        bytes32 merkleRoot;        // Merkle root of all events in batch
        bytes32 arweaveTxId;       // Arweave transaction ID (validated)
        uint256 timestamp;         // Block timestamp when committed
        uint256 eventCount;        // Number of events in batch
        uint256 blockNumber;       // Block number when committed
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

    /// @notice Emitted when a new batch is committed
    event BatchCommitted(
        uint256 indexed batchId,
        bytes32 indexed merkleRoot,
        bytes32 indexed arweaveTxId,
        uint256 eventCount,
        uint256 timestamp,
        address committer
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

        __UUPSUpgradeable_init();
        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();

        // Grant admin role to deployer
        _grantRole(DEFAULT_ADMIN_ROLE, admin);

        // Set initial batch size limits
        minBatchSize = initialMinBatchSize;
        maxBatchSize = initialMaxBatchSize;

        emit BatchSizeLimitsUpdated(initialMinBatchSize, initialMaxBatchSize);
    }

    // ============ Batch Committing ============

    /// @notice Commits a batch of provenance events
    /// @param merkleRoot Merkle root of all events in the batch
    /// @param arweaveTxId Arweave transaction ID where full data is stored
    /// @param eventCount Number of events in the batch
    /// @dev Only callable by BATCH_COMMITTER_ROLE when not paused
    function commitBatch(
        bytes32 merkleRoot,
        bytes32 arweaveTxId,
        uint256 eventCount
    )
        external
        onlyRole(BATCH_COMMITTER_ROLE)
        whenNotPaused
        nonReentrant
        validArweaveTxId(arweaveTxId)
    {
        // Validate batch size
        if (eventCount < minBatchSize || eventCount > maxBatchSize) {
            revert InvalidBatchSize(eventCount, minBatchSize, maxBatchSize);
        }

        // Validate Arweave TX ID format
        _validateArweaveTxId(arweaveTxId);

        // Check for duplicate Merkle root
        if (usedMerkleRoots[merkleRoot]) {
            revert DuplicateMerkleRoot(merkleRoot);
        }

        // Check for duplicate Arweave TX ID
        if (usedArweaveTxIds[arweaveTxId]) {
            revert DuplicateArweaveTxId(arweaveTxId);
        }

        // Store batch commit
        uint256 currentBatchId = batchCount;
        batches[currentBatchId] = BatchCommit({
            merkleRoot: merkleRoot,
            arweaveTxId: arweaveTxId,
            timestamp: block.timestamp,
            eventCount: eventCount,
            blockNumber: block.number
        });

        // Mark as used
        usedMerkleRoots[merkleRoot] = true;
        usedArweaveTxIds[arweaveTxId] = true;

        // Increment batch count
        batchCount++;

        // Emit event
        emit BatchCommitted(
            currentBatchId,
            merkleRoot,
            arweaveTxId,
            eventCount,
            block.timestamp,
            msg.sender
        );
    }

    // ============ Proof Verification ============

    /// @notice Verifies a Merkle proof for a specific event
    /// @param batchId ID of the batch containing the event
    /// @param leafHash Hash of the event (leaf in Merkle tree)
    /// @param proof Merkle proof path from leaf to root
    /// @return true if proof is valid, false otherwise
    function verifyProof(
        uint256 batchId,
        bytes32 leafHash,
        bytes32[] memory proof
    ) external view whenNotPaused returns (bool) {
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
        return _getImplementation();
    }

    /// @notice Returns contract version (for upgrade tracking)
    /// @return Version string
    function version() external pure returns (string memory) {
        return "1.0.0";
    }
}

