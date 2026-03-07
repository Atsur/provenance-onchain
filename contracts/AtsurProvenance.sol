// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import "./AtsurActorRegistry.sol";

/**
 * @title AtsurProvenance
 * @notice On-chain provenance anchoring for the Atsur art ecosystem.
 * @dev UUPS upgradeable. Admin = multisig (DEFAULT_ADMIN_ROLE). Committer = hot wallet (BATCH_COMMITTER_ROLE).
 *
 * ARCHITECTURE:
 * - All provenance events are CIDOC-CRM JSON-LD documents stored on Arweave.
 *   Only Merkle roots are anchored on-chain. arweaveTxId is the retrieval reference.
 *
 * - Batch ID = keccak256(abi.encodePacked(block.timestamp, submitterActorId, nonce)).
 *   Submitted nonce from backend ensures uniqueness even within the same block.
 *
 * - Batch submitters (BATCH_COMMITTER_ROLE) must be registered actors in AtsurActorRegistry.
 *   Their actorId is verified on every anchorBatch call.
 *
 * - Artwork registration and custody transfer are kept off-chain (indexed from events).
 *   recordArtworkCreation / recordCustodyTransfer / recordCertification verify a Merkle
 *   proof before emitting trustworthy events — indexers can rely on these without
 *   storing redundant state on-chain.
 *
 * - checkAuthorship uses a deterministic authorship leaf. The backend MUST include this
 *   leaf in every E12_Production / E65_Creation batch:
 *     leaf = keccak256(abi.encodePacked(AUTHORSHIP_LEAF_PREFIX, artworkId, creatorActorId))
 *   This enables independent on-chain authorship proof without storing artwork state.
 *   Phase 2: this function can be upgraded to delegate to a ZK verifier contract.
 *
 * CIDOC-CRM EVENT CLASSES:
 *   E12_Production           — artwork physical creation
 *   E65_Creation             — digital artwork creation
 *   E8_Acquisition           — ownership/custody transfer
 *   E13_Attribute_Assignment — NGA certification / attestation
 *   E11_Modification         — restoration, conservation
 *   E6_Destruction           — recorded destruction
 */
contract AtsurProvenance is UUPSUpgradeable, AccessControlUpgradeable, PausableUpgradeable {

    // ─────────────────────────────────────────────
    // ROLES
    // ─────────────────────────────────────────────

    /// @notice Role for committing provenance batches and recording indexed events
    bytes32 public constant BATCH_COMMITTER_ROLE = keccak256("BATCH_COMMITTER_ROLE");

    /// @notice Role for pausing batch commits (emergency)
    bytes32 public constant PAUSER_ROLE          = keccak256("PAUSER_ROLE");

    // ─────────────────────────────────────────────
    // AUTHORSHIP LEAF SCHEME
    // ─────────────────────────────────────────────

    /**
     * @notice Prefix used to compute deterministic authorship leaves.
     * @dev    Backend MUST include this leaf in every creation batch:
     *           leaf = keccak256(abi.encodePacked(AUTHORSHIP_LEAF_PREFIX, artworkId, creatorActorId))
     *         This allows checkAuthorship() to verify without any on-chain artwork state.
     */
    bytes32 public constant AUTHORSHIP_LEAF_PREFIX = keccak256("ATSUR_AUTHORSHIP_V1");

    // ─────────────────────────────────────────────
    // STRUCTS — gas-optimised slot packing
    // ─────────────────────────────────────────────

    /**
     * @dev Provenance batch record.
     *
     * Slot layout:
     *   0 : merkleRoot          (bytes32, 32)
     *   1 : arweaveTxId         (bytes32, 32)
     *   2 : submitterActorId    (bytes32, 32)
     *   3 : submittedBy (20) + timestamp (6) + exists (1) = 27
     *   4 : eventCount (4) + blockNumber (4) = 8
     *   5+: eventType           (string, dynamic)
     */
    struct ProvenanceBatch {
        bytes32 merkleRoot;
        bytes32 arweaveTxId;
        bytes32 submitterActorId;
        address submittedBy;
        uint48  timestamp;
        bool    exists;
        uint32  eventCount;
        uint32  blockNumber;
        string  eventType;
    }

    // ─────────────────────────────────────────────
    // STORAGE
    // ─────────────────────────────────────────────

    AtsurActorRegistry public actorRegistry;

    /// @notice batchId → ProvenanceBatch
    mapping(bytes32 => ProvenanceBatch) public batches;

    /// @notice Prevents the same Merkle root being anchored twice
    mapping(bytes32 => bool) public usedMerkleRoots;

    /// @notice Prevents the same Arweave TX ID being anchored twice
    mapping(bytes32 => bool) public usedArweaveTxIds;

    uint256 public minBatchSize;
    uint256 public maxBatchSize;

    // Reentrancy guard (avoids inheriting a whole contract for one variable)
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED     = 2;
    uint256 private _status;

    /// @dev Storage gap — reserve 50 slots for future upgrades
    uint256[50] private __gap;

    // ─────────────────────────────────────────────
    // EVENTS
    // ─────────────────────────────────────────────

    /// @notice Emitted when a Merkle batch is anchored on-chain.
    event BatchAnchored(
        bytes32 indexed batchId,
        bytes32         merkleRoot,
        bytes32         arweaveTxId,
        bytes32 indexed submitterActorId,
        uint256         eventCount,
        uint256         timestamp
    );

    /**
     * @notice Emitted for off-chain indexers after verifying an E12_Production / E65_Creation event.
     *         Proof was verified on-chain before emission — indexers can trust this event.
     */
    event ArtworkRegistered(
        bytes32 indexed artworkId,
        bytes32 indexed creatorActorId,
        bytes32 indexed batchId,
        bytes32         eventLeaf,
        uint256         timestamp
    );

    /**
     * @notice Emitted for off-chain indexers after verifying an E8_Acquisition event.
     *         Proof was verified on-chain before emission.
     */
    event CustodyTransferred(
        bytes32 indexed artworkId,
        bytes32 indexed fromActorId,
        bytes32 indexed toActorId,
        bytes32         attestorActorId,
        bytes32         verifierId,
        bytes32         batchId,
        string          transferType,
        uint256         timestamp
    );

    /**
     * @notice Emitted for off-chain indexers after verifying an E13_Attribute_Assignment event.
     *         Used for NGA Certificates of Authenticity and Travel Permits.
     *         Proof was verified on-chain before emission.
     */
    event ArtworkCertified(
        bytes32 indexed artworkId,
        bytes32 indexed attestorActorId,
        bytes32         verifierId,
        bytes32         batchId,
        uint256         timestamp
    );

    event BatchSizeLimitsUpdated(uint256 minSize, uint256 maxSize);

    event ProofVerified(bytes32 indexed batchId, bytes32 indexed leafHash, bool verified);

    // ─────────────────────────────────────────────
    // ERRORS
    // ─────────────────────────────────────────────

    error InvalidBatchSize(uint256 eventCount, uint256 minSize, uint256 maxSize);
    error InvalidArweaveTxId(bytes32 txId);
    error DuplicateMerkleRoot(bytes32 merkleRoot);
    error DuplicateArweaveTxId(bytes32 arweaveTxId);
    error BatchNotFound(bytes32 batchId);
    error InvalidMerkleProof();
    error SubmitterNotInRegistry(bytes32 submitterActorId);
    error AttestorNotActive(bytes32 attestorActorId);
    error RecipientNotInRegistry(bytes32 toActorId);
    error VerifierNotCertified(bytes32 verifierId);
    error EmptyEventType();
    error ZeroAddress();
    error ReentrantCall();

    // ─────────────────────────────────────────────
    // MODIFIERS
    // ─────────────────────────────────────────────

    modifier nonReentrant() {
        if (_status == _ENTERED) revert ReentrantCall();
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }

    modifier validArweaveTxId(bytes32 txId) {
        if (txId == bytes32(0)) revert InvalidArweaveTxId(txId);
        _;
    }

    modifier batchMustExist(bytes32 batchId) {
        if (!batches[batchId].exists) revert BatchNotFound(batchId);
        _;
    }

    // ─────────────────────────────────────────────
    // INITIALIZER
    // ─────────────────────────────────────────────

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialise the provenance contract.
     * @param admin           Multisig address — DEFAULT_ADMIN_ROLE (upgrade + admin authority).
     * @param registryAddress Deployed AtsurActorRegistry proxy address.
     * @param initialMin      Minimum events per batch.
     * @param initialMax      Maximum events per batch.
     */
    function initialize(
        address admin,
        address registryAddress,
        uint256 initialMin,
        uint256 initialMax
    ) public initializer {
        if (admin == address(0) || registryAddress == address(0)) revert ZeroAddress();
        if (initialMin == 0 || initialMax == 0 || initialMin > initialMax) {
            revert InvalidBatchSize(initialMin, initialMin, initialMax);
        }
        __AccessControl_init();
        __Pausable_init();

        _status        = _NOT_ENTERED;
        actorRegistry  = AtsurActorRegistry(registryAddress);
        minBatchSize   = initialMin;
        maxBatchSize   = initialMax;

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        emit BatchSizeLimitsUpdated(initialMin, initialMax);
    }

    // ─────────────────────────────────────────────
    // BATCH ANCHORING
    // ─────────────────────────────────────────────

    /**
     * @notice Anchor a Merkle root of a batch of CIDOC-CRM provenance events.
     *         Called by the off-chain cron job after building the Merkle tree and
     *         uploading the full batch payload to Arweave.
     *
     * @param merkleRoot        Root of the Merkle tree of CIDOC event hashes
     * @param arweaveTxId       Arweave TX ID where full batch payload is stored (bytes32 form)
     * @param eventCount        Number of events in this batch
     * @param submitterActorId  actorId of the Atsur operator — verified in AtsurActorRegistry
     * @param nonce             Random bytes32 to ensure batchId uniqueness within a block
     * @param eventType         Primary CIDOC class (e.g. "E12_Production", "E8_Acquisition")
     * @return batchId          keccak256(abi.encodePacked(block.timestamp, submitterActorId, nonce))
     */
    function anchorBatch(
        bytes32         merkleRoot,
        bytes32         arweaveTxId,
        uint32          eventCount,
        bytes32         submitterActorId,
        bytes32         nonce,
        string calldata eventType
    )
        external
        onlyRole(BATCH_COMMITTER_ROLE)
        whenNotPaused
        nonReentrant
        validArweaveTxId(arweaveTxId)
        returns (bytes32 batchId)
    {
        if (bytes(eventType).length == 0) revert EmptyEventType();
        if (eventCount < minBatchSize || eventCount > maxBatchSize) {
            revert InvalidBatchSize(eventCount, minBatchSize, maxBatchSize);
        }
        if (usedMerkleRoots[merkleRoot])    revert DuplicateMerkleRoot(merkleRoot);
        if (usedArweaveTxIds[arweaveTxId]) revert DuplicateArweaveTxId(arweaveTxId);

        if (!actorRegistry.actorExists(submitterActorId)) {
            revert SubmitterNotInRegistry(submitterActorId);
        }

        _validateArweaveTxId(arweaveTxId);

        batchId = keccak256(abi.encodePacked(block.timestamp, submitterActorId, nonce));

        batches[batchId] = ProvenanceBatch({
            merkleRoot:       merkleRoot,
            arweaveTxId:      arweaveTxId,
            submitterActorId: submitterActorId,
            submittedBy:      msg.sender,
            timestamp:        uint48(block.timestamp),
            exists:           true,
            eventCount:       eventCount,
            blockNumber:      uint32(block.number),
            eventType:        eventType
        });

        usedMerkleRoots[merkleRoot]   = true;
        usedArweaveTxIds[arweaveTxId] = true;

        emit BatchAnchored(batchId, merkleRoot, arweaveTxId, submitterActorId, eventCount, block.timestamp);
    }

    // ─────────────────────────────────────────────
    // OFF-CHAIN EVENT INDEXING
    // Verify Merkle proof then emit trustworthy events for indexers.
    // No artwork state is stored on-chain — custody is tracked off-chain.
    // ─────────────────────────────────────────────

    /**
     * @notice Record an artwork creation event for off-chain indexers.
     *         Emits ArtworkRegistered after verifying the Merkle proof.
     *         Called by backend after indexing an E12_Production or E65_Creation event.
     *
     * @param batchId         Batch containing the creation event
     * @param artworkId       keccak256(atsur_artwork_uuid)
     * @param creatorActorId  actorId of the artist — must be active in AtsurActorRegistry
     * @param eventLeaf       Merkle leaf of the creation event (keccak256 of CIDOC JSON-LD)
     * @param proof           Merkle proof path
     */
    function recordArtworkCreation(
        bytes32            batchId,
        bytes32            artworkId,
        bytes32            creatorActorId,
        bytes32            eventLeaf,
        bytes32[] calldata proof
    ) external onlyRole(BATCH_COMMITTER_ROLE) whenNotPaused batchMustExist(batchId) {
        _requireActiveActor(creatorActorId);
        _requireValidProof(proof, batches[batchId].merkleRoot, eventLeaf);

        emit ArtworkRegistered(artworkId, creatorActorId, batchId, eventLeaf, block.timestamp);
    }

    /**
     * @notice Record a custody transfer event for off-chain indexers.
     *         Emits CustodyTransferred after verifying the Merkle proof.
     *         Called by backend after indexing an E8_Acquisition event.
     *
     * @param batchId          Batch containing the transfer event
     * @param artworkId        The artwork being transferred
     * @param fromActorId      Current custodian (bytes32(0) for genesis / unknown)
     * @param toActorId        New custodian — must exist in AtsurActorRegistry
     * @param attestorActorId  Institution or Tier-1 actor certifying this transfer
     * @param verifierId       Opaque delegated verifier ID (bytes32(0) = direct attestation)
     * @param eventLeaf        Merkle leaf of the E8_Acquisition event
     * @param proof            Merkle proof path
     * @param transferType     "sale" | "loan" | "gift" | "export" | "bequest"
     */
    function recordCustodyTransfer(
        bytes32            batchId,
        bytes32            artworkId,
        bytes32            fromActorId,
        bytes32            toActorId,
        bytes32            attestorActorId,
        bytes32            verifierId,
        bytes32            eventLeaf,
        bytes32[] calldata proof,
        string    calldata transferType
    ) external onlyRole(BATCH_COMMITTER_ROLE) whenNotPaused batchMustExist(batchId) {
        if (!actorRegistry.actorExists(toActorId))   revert RecipientNotInRegistry(toActorId);
        _requireActiveActor(attestorActorId);

        if (verifierId != bytes32(0)) {
            if (!actorRegistry.isActiveVerifier(attestorActorId, verifierId)) {
                revert VerifierNotCertified(verifierId);
            }
        }

        _requireValidProof(proof, batches[batchId].merkleRoot, eventLeaf);

        emit CustodyTransferred(
            artworkId, fromActorId, toActorId,
            attestorActorId, verifierId, batchId,
            transferType, block.timestamp
        );
    }

    /**
     * @notice Record a certification event for off-chain indexers.
     *         Emits ArtworkCertified after verifying the Merkle proof.
     *         Called by backend after indexing an E13_Attribute_Assignment event
     *         (NGA Certificate of Authenticity, Travel Permit, etc.).
     *         Does NOT change custody — purely records the institutional attestation.
     *
     * @param batchId          Batch containing the certification event
     * @param artworkId        The artwork being certified
     * @param attestorActorId  NGA or certifying institution actorId — must be active
     * @param verifierId       Delegated verifier ID (bytes32(0) = direct NGA officer)
     * @param eventLeaf        Merkle leaf of the E13 event
     * @param proof            Merkle proof path
     */
    function recordCertification(
        bytes32            batchId,
        bytes32            artworkId,
        bytes32            attestorActorId,
        bytes32            verifierId,
        bytes32            eventLeaf,
        bytes32[] calldata proof
    ) external onlyRole(BATCH_COMMITTER_ROLE) whenNotPaused batchMustExist(batchId) {
        _requireActiveActor(attestorActorId);

        if (verifierId != bytes32(0)) {
            if (!actorRegistry.isActiveVerifier(attestorActorId, verifierId)) {
                revert VerifierNotCertified(verifierId);
            }
        }

        _requireValidProof(proof, batches[batchId].merkleRoot, eventLeaf);

        emit ArtworkCertified(artworkId, attestorActorId, verifierId, batchId, block.timestamp);
    }

    // ─────────────────────────────────────────────
    // AUTHORSHIP CHECK
    // ─────────────────────────────────────────────

    /**
     * @notice Verify on-chain that a specific actor created a specific artwork.
     *         Works against the Merkle batch — no on-chain artwork state needed.
     *
     *         REQUIREMENT: backend MUST include the following leaf in every
     *         E12_Production / E65_Creation batch before calling anchorBatch():
     *           leaf = keccak256(abi.encodePacked(AUTHORSHIP_LEAF_PREFIX, artworkId, creatorActorId))
     *
     *         Phase 2: this function can be upgraded to delegate to a ZK verifier contract
     *         that proves the content of the CIDOC event without revealing it.
     *
     * @param batchId         Batch that contains the creation event
     * @param artworkId       keccak256(atsur_artwork_uuid)
     * @param creatorActorId  The claimed creator's actorId
     * @param proof           Merkle proof for the authorship leaf
     * @return true if the creator is provably recorded in this batch
     */
    function checkAuthorship(
        bytes32            batchId,
        bytes32            artworkId,
        bytes32            creatorActorId,
        bytes32[] calldata proof
    ) external view batchMustExist(batchId) returns (bool) {
        bytes32 leaf = keccak256(abi.encodePacked(AUTHORSHIP_LEAF_PREFIX, artworkId, creatorActorId));
        return MerkleProof.verifyCalldata(proof, batches[batchId].merkleRoot, leaf);
    }

    // ─────────────────────────────────────────────
    // PROOF VERIFICATION
    // ─────────────────────────────────────────────

    /**
     * @notice Verifies a Merkle proof and emits ProofVerified event.
     *         Use verifyProofView for read-only verification.
     */
    function verifyProof(
        bytes32         batchId,
        bytes32         leafHash,
        bytes32[] memory proof
    ) external whenNotPaused batchMustExist(batchId) returns (bool isValid) {
        isValid = MerkleProof.verify(proof, batches[batchId].merkleRoot, leafHash);
        emit ProofVerified(batchId, leafHash, isValid);
    }

    /// @notice Verifies a Merkle proof — view, no event emitted. Gas-efficient for off-chain reads.
    function verifyProofView(
        bytes32         batchId,
        bytes32         leafHash,
        bytes32[] memory proof
    ) external view batchMustExist(batchId) returns (bool) {
        return MerkleProof.verify(proof, batches[batchId].merkleRoot, leafHash);
    }

    /**
     * @notice Verify a leaf is in a batch using calldata proof — cheapest gas path.
     *         Matches the sorted-pair Merkle scheme used by the backend CidocEventEncoder.
     */
    function verifyProvenanceEvent(
        bytes32            batchId,
        bytes32            leaf,
        bytes32[] calldata proofPath
    ) external view batchMustExist(batchId) returns (bool) {
        return MerkleProof.verifyCalldata(proofPath, batches[batchId].merkleRoot, leaf);
    }

    // ─────────────────────────────────────────────
    // BATCH INFORMATION
    // ─────────────────────────────────────────────

    function getBatch(bytes32 batchId) external view batchMustExist(batchId) returns (ProvenanceBatch memory) {
        return batches[batchId];
    }

    // ─────────────────────────────────────────────
    // CONFIGURATION
    // ─────────────────────────────────────────────

    function setBatchSizeLimits(uint256 newMin, uint256 newMax) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newMin == 0 || newMax == 0 || newMin > newMax) {
            revert InvalidBatchSize(newMin, newMin, newMax);
        }
        minBatchSize = newMin;
        maxBatchSize = newMax;
        emit BatchSizeLimitsUpdated(newMin, newMax);
    }

    /// @notice Update the registry address (e.g. after a registry upgrade).
    function setActorRegistry(address newRegistry) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newRegistry == address(0)) revert ZeroAddress();
        actorRegistry = AtsurActorRegistry(newRegistry);
    }

    // ─────────────────────────────────────────────
    // PAUSE
    // ─────────────────────────────────────────────

    function pauseBatchCommits() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpauseBatchCommits() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    // ─────────────────────────────────────────────
    // VIEW FUNCTIONS
    // ─────────────────────────────────────────────

    function getImplementation() external view returns (address) {
        return ERC1967Utils.getImplementation();
    }

    function version() external pure returns (string memory) {
        return "2.0.0";
    }

    // ─────────────────────────────────────────────
    // INTERNAL
    // ─────────────────────────────────────────────

    function _requireActiveActor(bytes32 actorId) internal view {
        AtsurActorRegistry.Actor memory a = actorRegistry.getActor(actorId);
        if (a.status != AtsurActorRegistry.ActorStatus.Active) {
            revert AttestorNotActive(actorId);
        }
    }

    function _requireValidProof(
        bytes32[] calldata proof,
        bytes32            root,
        bytes32            leaf
    ) internal pure {
        if (!MerkleProof.verifyCalldata(proof, root, leaf)) revert InvalidMerkleProof();
    }

    function _validateArweaveTxId(bytes32 txId) internal pure {
        if (txId == bytes32(0)) revert InvalidArweaveTxId(txId);
        // Reject low-entropy IDs (e.g. all same byte) — real Arweave TX IDs are high-entropy
        uint8 first   = uint8(txId[0]);
        bool  allSame = true;
        for (uint256 i = 1; i < 32; i++) {
            if (uint8(txId[i]) != first) {
                allSame = false;
                break;
            }
        }
        if (allSame && first != 0) revert InvalidArweaveTxId(txId);
    }

    // ─────────────────────────────────────────────
    // UUPS — upgrade authorisation
    // ─────────────────────────────────────────────

    /// @dev Only DEFAULT_ADMIN_ROLE (multisig) can authorise upgrades.
    function _authorizeUpgrade(address /*newImplementation*/) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
