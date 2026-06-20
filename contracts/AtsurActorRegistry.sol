// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

/**
 * @title AtsurActorRegistry
 * @notice Canonical on-chain identity registry for all actors in the Atsur provenance system.
 * @dev UUPS upgradeable. Admin = multisig (DEFAULT_ADMIN_ROLE). Operator = hot wallet (OPERATOR_ROLE).
 *      Upgrades are gated by UPGRADER_ROLE, which should be held by a TimelockController — see
 *      scripts/setupTimelock.js. UPGRADER_ROLE is self-administered (see initialize()) — only a
 *      current UPGRADER_ROLE holder can grant/revoke it; DEFAULT_ADMIN_ROLE cannot.
 *
 * DESIGN PRINCIPLES:
 * - Atsur platform UUIDs are the canonical actor identity. KYC providers (Smile ID, Persona, etc.)
 *   are attestation credentials attached to a UUID — not the identity itself.
 *   actorId = keccak256(atsur_uuid) — computed off-chain, stable forever.
 *
 * - Wallets link to actorIds, not the reverse. A user can add a self-custodial wallet later;
 *   all historical provenance remains valid via actorId. Changing wallets is cosmetic.
 *
 * - Two-tier actor model:
 *     Tier 1 — KYC/KYB verified (individuals + organisations). Full identity commitment.
 *     Tier 2 — Delegated verifiers under an institution's trust boundary.
 *              Institution is accountable on-chain; verifier is pseudonymous.
 *              verifierId = keccak256(atsur_internal_verifier_uuid) — opaque on-chain.
 *
 * - Provider-agnostic: kycCommitment = keccak256(providerName + userId + atsurUuid + salt).
 *   providerName stored in clear; personal data never on-chain.
 *   Switching providers → call updateKycCommitment(); actorId stays the same.
 *
 * CIDOC-CRM ACTOR TYPES SUPPORTED:
 *   E21_Person     — individual artist, collector, owner
 *   E74_Group      — gallery, studio, foundation
 *   E40_LegalBody  — NGA, government institution, registered company
 */
contract AtsurActorRegistry is UUPSUpgradeable, AccessControlUpgradeable {

    // ─────────────────────────────────────────────
    // ROLES
    // ─────────────────────────────────────────────

    /// @notice Hot wallet for routine operations (registerActor, updateKycCommitment, etc.)
    bytes32 public constant OPERATOR_ROLE  = keccak256("OPERATOR_ROLE");

    /// @notice Authorises contract upgrades — should be held by a TimelockController, not the admin directly.
    bytes32 public constant UPGRADER_ROLE  = keccak256("UPGRADER_ROLE");

    // ─────────────────────────────────────────────
    // ENUMS
    // ─────────────────────────────────────────────

    enum ActorType   { E21_Person, E74_Group, E40_LegalBody }
    enum ActorTier   { KYC_Verified, Delegated }
    enum ActorStatus { Active, Suspended, Revoked }

    // ─────────────────────────────────────────────
    // STRUCTS — gas-optimised slot packing
    // ─────────────────────────────────────────────

    /**
     * @dev Core actor record. actorId = keccak256(atsur_uuid).
     *      Existence is determined by registeredAt != 0 (set on registration, never reset).
     *
     * Slot layout:
     *   0 : kycCommitment          (bytes32, 32)
     *   1 : delegatingInstitutionId(bytes32, 32)
     *   2 : custodialWallet (20) + registeredAt (6) + actorType (1) + tier (1) + status (1) = 29
     *   3 : selfCustodialWallet (20) + updatedAt (6) = 26
     *   4+: kycProvider            (string, dynamic)
     */
    struct Actor {
        bytes32     kycCommitment;
        bytes32     delegatingInstitutionId;
        address     custodialWallet;
        uint48      registeredAt;
        ActorType   actorType;
        ActorTier   tier;
        ActorStatus status;
        address     selfCustodialWallet;
        uint48      updatedAt;
        string      kycProvider;
    }

    /**
     * @dev Wallet link history record — proves both wallets belong to the same actor.
     *
     * Slot layout:
     *   0 : actorId         (bytes32, 32)
     *   1 : linkCommitment  (bytes32, 32)
     *   2 : oldWallet (20) + linkedAt (6) = 26
     *   3 : newWallet       (address, 20)
     */
    struct WalletLink {
        bytes32 actorId;
        bytes32 linkCommitment;
        address oldWallet;
        uint48  linkedAt;
        address newWallet;
    }

    /**
     * @dev Institution verifier pool entry.
     *
     * Slot layout:
     *   0 : verifierId          (bytes32, 32)
     *   1 : institutionActorId  (bytes32, 32)
     *   2 : delegatedAt (6) + certifiedAt (6) + trainingCertified (1) + active (1) = 14
     */
    struct VerifierDelegation {
        bytes32 verifierId;
        bytes32 institutionActorId;
        uint48  delegatedAt;
        uint48  certifiedAt;
        bool    trainingCertified;
        bool    active;
    }

    // ─────────────────────────────────────────────
    // STORAGE
    // ─────────────────────────────────────────────

    /// @notice actorId → Actor
    mapping(bytes32 => Actor)                                  public actors;

    /// @notice wallet → actorId (both custodial and self-custodial indexed here)
    mapping(address => bytes32)                                public walletToActor;

    /// @notice actorId → wallet link history
    mapping(bytes32 => WalletLink[])                           public walletLinks;

    /// @notice institutionActorId → verifierId → VerifierDelegation
    mapping(bytes32 => mapping(bytes32 => VerifierDelegation)) public verifierDelegations;

    /// @notice institutionActorId → verifierId[] (for enumeration)
    mapping(bytes32 => bytes32[])                              public institutionVerifiers;

    /// @notice verifierId → institutionActorId (reverse lookup)
    mapping(bytes32 => bytes32)                                public verifierToInstitution;

    /// @notice verifierId → permanently revoked (cannot be re-delegated after revocation)
    mapping(bytes32 => bool)                                   public revokedVerifiers;

    /// @dev Storage gap — 50 slots (actorExists removed, 1 consumed by revokedVerifiers)
    uint256[50] private __gap;

    // ─────────────────────────────────────────────
    // EVENTS
    // ─────────────────────────────────────────────

    event ActorRegistered(
        bytes32 indexed actorId,
        ActorType       actorType,
        ActorTier       tier,
        string          kycProvider,
        address         custodialWallet,
        uint256         timestamp
    );

    event WalletLinked(
        bytes32 indexed actorId,
        address indexed oldWallet,
        address indexed newWallet,
        bytes32         linkCommitment,
        uint256         timestamp
    );

    event ActorStatusChanged(
        bytes32 indexed actorId,
        ActorStatus     newStatus,
        address         changedBy,
        uint256         timestamp
    );

    event KycCommitmentUpdated(
        bytes32 indexed actorId,
        string          newProvider,
        bytes32         newCommitment,
        uint256         timestamp
    );

    event VerifierDelegated(
        bytes32 indexed institutionActorId,
        bytes32 indexed verifierId,
        bool            trainingCertified,
        uint256         timestamp
    );

    event VerifierRevoked(
        bytes32 indexed institutionActorId,
        bytes32 indexed verifierId,
        address         revokedBy,
        uint256         timestamp
    );

    event VerifierTrainingCertified(
        bytes32 indexed verifierId,
        bytes32 indexed institutionActorId,
        uint256         timestamp
    );

    /**
     * @notice Emitted when a verifier is delegated without training certification.
     * @dev Backend listens for this to track pending training requirements.
     *      Training certification must be triggered by registry-cloud's
     *      ActorRegistryService.certifyVerifierTraining() webhook on training completion.
     */
    event VerifierTrainingPending(
        bytes32 indexed institutionActorId,
        bytes32 indexed verifierId,
        uint256         timestamp
    );

    // ─────────────────────────────────────────────
    // ERRORS
    // ─────────────────────────────────────────────

    error InvalidActorId();
    error ActorAlreadyRegistered(bytes32 actorId);
    error ActorNotFound(bytes32 actorId);
    error ActorNotActive(bytes32 actorId);
    error InvalidWallet();
    error WalletAlreadyMapped(address wallet);
    error WalletAlreadyLinked(bytes32 actorId);
    error InvalidLinkCommitment();
    error InvalidKycProvider();
    error NotAtsur();
    error NotInstitutionOrAtsur();
    error OnlyGroupsOrLegalBodiesCanDelegate();
    error VerifierAlreadyActive(bytes32 verifierId);
    error VerifierAlreadyDelegatedElsewhere(bytes32 verifierId);
    error VerifierNotActive(bytes32 verifierId);
    error VerifierAlreadyCertified(bytes32 verifierId);
    error VerifierPermanentlyRevoked(bytes32 verifierId);
    error ZeroAddress();
    error NotAContract(address addr);
    error WalletNotMapped(address wallet);

    // ─────────────────────────────────────────────
    // MODIFIERS
    // ─────────────────────────────────────────────

    modifier onlyAtsur() {
        if (!hasRole(OPERATOR_ROLE, msg.sender) && !hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) {
            revert NotAtsur();
        }
        _;
    }

    modifier onlyInstitutionOrAtsur(bytes32 institutionActorId) {
        bytes32 callerActorId = walletToActor[msg.sender];
        bool isInstitution    = callerActorId == institutionActorId &&
                                actors[institutionActorId].status == ActorStatus.Active;
        bool isAtsur          = hasRole(OPERATOR_ROLE, msg.sender) ||
                                hasRole(DEFAULT_ADMIN_ROLE, msg.sender);
        if (!isInstitution && !isAtsur) revert NotInstitutionOrAtsur();
        _;
    }

    modifier actorMustExist(bytes32 actorId) {
        if (actors[actorId].registeredAt == 0) revert ActorNotFound(actorId);
        _;
    }

    modifier actorMustBeActive(bytes32 actorId) {
        if (actors[actorId].registeredAt == 0 || actors[actorId].status != ActorStatus.Active) {
            revert ActorNotActive(actorId);
        }
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
     * @notice Initialise the registry.
     * @param admin    Multisig address — granted DEFAULT_ADMIN_ROLE (admin authority) and
     *                 UPGRADER_ROLE (upgrade authority). Transfer UPGRADER_ROLE to a
     *                 TimelockController via setupTimelock.js before mainnet use.
     * @param operator Hot wallet address — granted OPERATOR_ROLE (routine operations).
     */
    function initialize(address admin, address operator) public initializer {
        if (admin == address(0) || operator == address(0)) revert ZeroAddress();
        __AccessControl_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);
        // UPGRADER_ROLE is self-administered: only a current UPGRADER_ROLE holder (the
        // TimelockController, once transferred) can grant/revoke it. DEFAULT_ADMIN_ROLE
        // (the Safe) cannot re-grant itself upgrade authority and bypass the timelock.
        _setRoleAdmin(UPGRADER_ROLE, UPGRADER_ROLE);
        _grantRole(OPERATOR_ROLE, operator);
    }

    // ─────────────────────────────────────────────
    // ACTOR REGISTRATION — Tier 1 (KYC/KYB verified)
    // ─────────────────────────────────────────────

    /**
     * @notice Register a KYC/KYB-verified actor (individual or organisation).
     *         Called by Atsur backend after successful KYC callback from any provider.
     *
     * @param actorId         keccak256(atsur_platform_uuid) — computed off-chain
     * @param actorType       E21_Person | E74_Group | E40_LegalBody
     * @param kycCommitment   keccak256(abi.encodePacked(providerName, providerUserId, atsurUuid, salt))
     * @param kycProvider     "smile_id" | "persona" | "onfido"
     * @param custodialWallet Biconomy-provisioned wallet address
     */
    function registerActor(
        bytes32         actorId,
        ActorType       actorType,
        bytes32         kycCommitment,
        string calldata kycProvider,
        address         custodialWallet
    ) external onlyAtsur {
        if (actorId == bytes32(0))                         revert InvalidActorId();
        if (actors[actorId].registeredAt != 0)             revert ActorAlreadyRegistered(actorId);
        if (custodialWallet == address(0))                 revert InvalidWallet();
        if (walletToActor[custodialWallet] != bytes32(0)) revert WalletAlreadyMapped(custodialWallet);
        if (bytes(kycProvider).length == 0)               revert InvalidKycProvider();

        actors[actorId] = Actor({
            kycCommitment:            kycCommitment,
            delegatingInstitutionId:  bytes32(0),
            custodialWallet:          custodialWallet,
            registeredAt:             uint48(block.timestamp),
            actorType:                actorType,
            tier:                     ActorTier.KYC_Verified,
            status:                   ActorStatus.Active,
            selfCustodialWallet:      address(0),
            updatedAt:                uint48(block.timestamp),
            kycProvider:              kycProvider
        });

        walletToActor[custodialWallet] = actorId;

        emit ActorRegistered(actorId, actorType, ActorTier.KYC_Verified, kycProvider, custodialWallet, block.timestamp);
    }

    // ─────────────────────────────────────────────
    // WALLET LINKING — Biconomy → MetaMask
    // ─────────────────────────────────────────────

    /**
     * @notice Link a self-custodial wallet to an existing actor.
     *         All historical provenance remains valid via actorId.
     *         Both wallets remain active and map to the same actorId.
     *
     * @dev TRUST ASSUMPTION: the operator (onlyAtsur) fully controls the nonce and
     *      therefore can compute a valid linkCommitment for any newWallet without proof of
     *      that wallet's consent. ECDSA signature verification from newWallet is deferred
     *      to a future upgrade. Do not expose this function to untrusted operators.
     *
     * @param actorId        The actor linking their wallet
     * @param newWallet      The self-custodial wallet (MetaMask, etc.)
     * @param nonce          Random bytes32 from backend — prevents replay
     * @param linkCommitment keccak256(abi.encodePacked(actorId, custodialWallet, newWallet, nonce))
     */
    function linkSelfCustodialWallet(
        bytes32 actorId,
        address newWallet,
        bytes32 nonce,
        bytes32 linkCommitment
    ) external onlyAtsur actorMustBeActive(actorId) {
        Actor storage actor = actors[actorId];
        if (actor.selfCustodialWallet != address(0))      revert WalletAlreadyLinked(actorId);
        if (newWallet == address(0))                       revert InvalidWallet();
        if (walletToActor[newWallet] != bytes32(0))       revert WalletAlreadyMapped(newWallet);

        bytes32 expected = keccak256(abi.encodePacked(actorId, actor.custodialWallet, newWallet, nonce));
        if (linkCommitment != expected)                    revert InvalidLinkCommitment();

        walletLinks[actorId].push(WalletLink({
            actorId:        actorId,
            linkCommitment: linkCommitment,
            oldWallet:      actor.custodialWallet,
            linkedAt:       uint48(block.timestamp),
            newWallet:      newWallet
        }));

        actor.selfCustodialWallet = newWallet;
        actor.updatedAt           = uint48(block.timestamp);
        walletToActor[newWallet]  = actorId;

        emit WalletLinked(actorId, actor.custodialWallet, newWallet, linkCommitment, block.timestamp);
    }

    // ─────────────────────────────────────────────
    // KYC COMMITMENT UPDATE — provider switch / re-verify
    // ─────────────────────────────────────────────

    /**
     * @notice Update KYC commitment when switching providers or re-verifying.
     *         E.g. switching from Smile ID to Persona for European expansion.
     *         Old commitment is overwritten; the chain event log preserves full history.
     */
    function updateKycCommitment(
        bytes32         actorId,
        bytes32         newCommitment,
        string calldata newProvider
    ) external onlyAtsur actorMustExist(actorId) {
        if (bytes(newProvider).length == 0) revert InvalidKycProvider();

        Actor storage actor = actors[actorId];
        actor.kycCommitment = newCommitment;
        actor.kycProvider   = newProvider;
        actor.updatedAt     = uint48(block.timestamp);

        emit KycCommitmentUpdated(actorId, newProvider, newCommitment, block.timestamp);
    }

    // ─────────────────────────────────────────────
    // VERIFIER DELEGATION — Tier 2
    // ─────────────────────────────────────────────

    /**
     * @notice Institution delegates a verifier into their pool.
     *         Can be called by the institution's wallet or Atsur (override).
     *         Verifier must be training-certified before isActiveVerifier() returns true.
     *
     * @param institutionActorId  The delegating institution (E74_Group or E40_LegalBody)
     * @param verifierId          keccak256(atsur_internal_verifier_uuid) — opaque on-chain
     * @param trainingCertified   Whether verifier already completed Atsur training
     * @param certifiedAt         Training certification timestamp (0 if not yet certified)
     */
    function delegateVerifier(
        bytes32 institutionActorId,
        bytes32 verifierId,
        bool    trainingCertified,
        uint48  certifiedAt
    ) external onlyInstitutionOrAtsur(institutionActorId) actorMustBeActive(institutionActorId) {
        if (verifierId == bytes32(0))                                    revert InvalidActorId();
        if (actors[institutionActorId].actorType == ActorType.E21_Person) {
            revert OnlyGroupsOrLegalBodiesCanDelegate();
        }
        if (verifierDelegations[institutionActorId][verifierId].active) {
            revert VerifierAlreadyActive(verifierId);
        }
        if (revokedVerifiers[verifierId])                   revert VerifierPermanentlyRevoked(verifierId);
        if (verifierToInstitution[verifierId] != bytes32(0)) {
            revert VerifierAlreadyDelegatedElsewhere(verifierId);
        }

        verifierDelegations[institutionActorId][verifierId] = VerifierDelegation({
            verifierId:         verifierId,
            institutionActorId: institutionActorId,
            delegatedAt:        uint48(block.timestamp),
            certifiedAt:        certifiedAt,
            trainingCertified:  trainingCertified,
            active:             true
        });

        institutionVerifiers[institutionActorId].push(verifierId);
        verifierToInstitution[verifierId] = institutionActorId;

        // Signal pending training requirement to backend listeners
        if (!trainingCertified) {
            emit VerifierTrainingPending(institutionActorId, verifierId, block.timestamp);
        }

        emit VerifierDelegated(institutionActorId, verifierId, trainingCertified, block.timestamp);
    }

    /**
     * @notice Record training certification for a delegated verifier.
     *         Only Atsur can call — institutions cannot self-certify their verifiers.
     *         Until this is called, isActiveVerifier() returns false even if delegated.
     * @dev Training certification must be triggered by registry-cloud's
     *      ActorRegistryService.certifyVerifierTraining() webhook on training completion.
     */
    function certifyVerifierTraining(
        bytes32 institutionActorId,
        bytes32 verifierId
    ) external onlyAtsur {
        VerifierDelegation storage d = verifierDelegations[institutionActorId][verifierId];
        if (!d.active)           revert VerifierNotActive(verifierId);
        if (d.trainingCertified) revert VerifierAlreadyCertified(verifierId);

        d.trainingCertified = true;
        d.certifiedAt       = uint48(block.timestamp);

        emit VerifierTrainingCertified(verifierId, institutionActorId, block.timestamp);
    }

    /**
     * @notice Revoke a delegated verifier.
     *         Institution can revoke their own; Atsur can revoke any (platform override).
     *         Backend should invalidate the verifier's session immediately on revocation
     *         before waiting for on-chain confirmation.
     */
    function revokeVerifier(
        bytes32 institutionActorId,
        bytes32 verifierId
    ) external onlyInstitutionOrAtsur(institutionActorId) {
        VerifierDelegation storage d = verifierDelegations[institutionActorId][verifierId];
        if (!d.active) revert VerifierNotActive(verifierId);

        d.active                          = false;
        verifierToInstitution[verifierId] = bytes32(0);
        revokedVerifiers[verifierId]      = true;

        emit VerifierRevoked(institutionActorId, verifierId, msg.sender, block.timestamp);
    }

    /**
     * @notice Clear a verifier's permanent revocation flag, allowing re-delegation.
     *         Only DEFAULT_ADMIN_ROLE (multisig) can call — requires human review before use.
     *         The verifier still needs to be re-delegated via delegateVerifier() afterward.
     */
    function clearVerifierRevocation(bytes32 verifierId) external onlyRole(DEFAULT_ADMIN_ROLE) {
        revokedVerifiers[verifierId] = false;
    }

    // ─────────────────────────────────────────────
    // ACTOR STATUS MANAGEMENT
    // ─────────────────────────────────────────────

    function setActorStatus(
        bytes32     actorId,
        ActorStatus newStatus
    ) external onlyAtsur actorMustExist(actorId) {
        actors[actorId].status    = newStatus;
        actors[actorId].updatedAt = uint48(block.timestamp);
        emit ActorStatusChanged(actorId, newStatus, msg.sender, block.timestamp);
    }

    // ─────────────────────────────────────────────
    // VIEW FUNCTIONS
    // ─────────────────────────────────────────────

    function getActor(bytes32 actorId) external view returns (Actor memory) {
        return actors[actorId];
    }

    function getActorByWallet(address wallet) external view returns (Actor memory) {
        bytes32 actorId = walletToActor[wallet];
        if (actorId == bytes32(0)) revert WalletNotMapped(wallet);
        return actors[actorId];
    }

    /// @notice Returns true if the actor is registered (existence check, ignores status).
    function isActorRegistered(bytes32 actorId) external view returns (bool) {
        return actors[actorId].registeredAt != 0;
    }

    /// @notice Returns true if the actor is registered and currently Active.
    function isActorActive(bytes32 actorId) external view returns (bool) {
        return actors[actorId].registeredAt != 0 &&
               actors[actorId].status == ActorStatus.Active;
    }

    /// @notice Returns true only if the verifier is both active AND training-certified.
    function isActiveVerifier(
        bytes32 institutionActorId,
        bytes32 verifierId
    ) external view returns (bool) {
        VerifierDelegation storage d = verifierDelegations[institutionActorId][verifierId];
        return d.active && d.trainingCertified;
    }

    /// @notice Returns true if delegated (regardless of training certification).
    function isVerifierDelegated(
        bytes32 institutionActorId,
        bytes32 verifierId
    ) external view returns (bool) {
        return verifierDelegations[institutionActorId][verifierId].active;
    }

    function getInstitutionVerifiers(bytes32 institutionActorId) external view returns (bytes32[] memory) {
        return institutionVerifiers[institutionActorId];
    }

    function getWalletLinkHistory(bytes32 actorId) external view returns (WalletLink[] memory) {
        return walletLinks[actorId];
    }

    // BREAKING CHANGE (audit SEV-001): salt parameter removed.
    // registry-cloud: update ActorRegistryService.verifyKycCommitment() call site.
    // Third-party callers: pass actors[actorId].kycCommitment to compare off-chain.

    /**
     * @notice Verify that a claimed KYC commitment matches the actor's on-chain record.
     *         Callers should compute keccak256(providerName, providerUserId, atsurUuid, salt)
     *         off-chain and pass the resulting hash here — the salt never touches the chain.
     *
     * @param actorId           The actor to verify
     * @param claimedCommitment keccak256(abi.encodePacked(providerName, providerUserId, atsurUuid, salt))
     *                          computed off-chain by the verifier
     */
    function verifyKycCommitment(
        bytes32 actorId,
        bytes32 claimedCommitment
    ) external view actorMustExist(actorId) returns (bool) {
        return claimedCommitment == actors[actorId].kycCommitment &&
               actors[actorId].status == ActorStatus.Active;
    }

    function version() external pure returns (string memory) {
        return "1.0.0";
    }

    // ─────────────────────────────────────────────
    // UUPS — upgrade authorisation
    // ─────────────────────────────────────────────

    /// @dev Only UPGRADER_ROLE (TimelockController) can authorise upgrades.
    ///      UPGRADER_ROLE is self-administered — DEFAULT_ADMIN_ROLE cannot grant it to itself or
    ///      anyone else; only a current UPGRADER_ROLE holder can transfer it.
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {
        if (newImplementation.code.length == 0) revert NotAContract(newImplementation);
    }
}
