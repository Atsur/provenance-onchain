/**
 * ActorRegistryService.js
 *
 * Backend service layer between the Atsur platform and AtsurActorRegistry contract.
 *
 * HANDLES:
 *   1. KYC callback → build commitment → register actor on-chain
 *   2. KYC provider switch → update commitment, actorId unchanged
 *   3. Wallet linking: Biconomy custodial → MetaMask self-custodial
 *   4. Institution delegation of verifiers
 *   5. Verifier training certification (TODO: wire to course completion webhook)
 *   6. Verifier revocation (institution or Atsur override)
 *   7. Actor status management (suspend, revoke, reinstate)
 *
 * REAL-WORLD FLOW:
 *   User signs up on atsur.art
 *   → Biconomy creates custodial wallet
 *   → User completes Smile ID KYC
 *   → Smile ID POSTs callback to /kyc/callback
 *   → handleKycCallback() builds commitment + registers actor on-chain
 *   → Later: user connects MetaMask via /actor/link-wallet
 *   → linkSelfCustodialWallet() — one tx; all history stays valid via actorId
 */

const { ethers }                     = require("ethers");
const { IdentityCommitmentService }  = require("./IdentityCommitmentService");
const crypto                         = require("crypto");

// ─────────────────────────────────────────────
// ABI — only the functions this service calls
// ─────────────────────────────────────────────

const ACTOR_REGISTRY_ABI = [
    // Write
    "function registerActor(bytes32 actorId, uint8 actorType, bytes32 kycCommitment, string kycProvider, address custodialWallet) external",
    "function linkSelfCustodialWallet(bytes32 actorId, address newWallet, bytes32 nonce, bytes32 linkCommitment) external",
    "function updateKycCommitment(bytes32 actorId, bytes32 newCommitment, string newProvider) external",
    "function delegateVerifier(bytes32 institutionActorId, bytes32 verifierId, bool trainingCertified, uint48 certifiedAt) external",
    "function certifyVerifierTraining(bytes32 institutionActorId, bytes32 verifierId) external",
    "function revokeVerifier(bytes32 institutionActorId, bytes32 verifierId) external",
    "function setActorStatus(bytes32 actorId, uint8 newStatus) external",
    // Read
    "function getActor(bytes32 actorId) external view returns (tuple(bytes32 actorId, bytes32 kycCommitment, bytes32 delegatingInstitutionId, address custodialWallet, uint48 registeredAt, uint8 actorType, uint8 tier, uint8 status, address selfCustodialWallet, uint48 updatedAt, string kycProvider))",
    "function isActiveVerifier(bytes32 institutionActorId, bytes32 verifierId) external view returns (bool)",
    "function actorExists(bytes32 actorId) external view returns (bool)",
    "function walletToActor(address wallet) external view returns (bytes32)",
];

// CIDOC-CRM actor type → contract enum index (must match AtsurActorRegistry.ActorType)
const ACTOR_TYPE_MAP = {
    E21_Person:    0,
    E74_Group:     1,
    E40_LegalBody: 2,
};

// Actor status → contract enum index (must match AtsurActorRegistry.ActorStatus)
const ACTOR_STATUS_MAP = {
    Active:    0,
    Suspended: 1,
    Revoked:   2,
};

class ActorRegistryService {

    /**
     * @param {object} config
     * @param {string} config.rpcUrl             Lisk Sepolia RPC endpoint
     * @param {string} config.registryAddress    AtsurActorRegistry proxy address
     * @param {string} config.operatorPrivateKey Atsur operator wallet private key (OPERATOR_ROLE)
     * @param {object} config.db                 Database client. Must implement:
     *                                             getSalt(uuid) → string | null
     *                                             saveSalt(uuid, salt) → void
     *                                             saveActorRecord(record) → void
     */
    constructor(config) {
        this.provider       = new ethers.JsonRpcProvider(config.rpcUrl);
        this.operatorWallet = new ethers.Wallet(config.operatorPrivateKey, this.provider);
        this.registry       = new ethers.Contract(
            config.registryAddress,
            ACTOR_REGISTRY_ABI,
            this.operatorWallet
        );
        this.db = config.db;
    }

    // ─────────────────────────────────────────────
    // KYC CALLBACK HANDLER
    // Called by your webhook endpoint when Smile ID (or any provider) posts a result.
    // ─────────────────────────────────────────────

    /**
     * Process a KYC verification callback and register (or update) the actor on-chain.
     *
     * @param {string} providerName       "smile_id" | "stub"
     * @param {object} providerResponse   Raw callback payload from the provider
     * @param {string} atsurUuid          Your platform UUID for this user
     * @param {string} custodialWallet    Biconomy wallet address for this user
     * @param {string} cidocActorType     "E21_Person" | "E74_Group" | "E40_LegalBody"
     * @returns {Promise<object>}
     */
    async handleKycCallback(
        providerName,
        providerResponse,
        atsurUuid,
        custodialWallet,
        cidocActorType = "E21_Person"
    ) {
        // 1. Retrieve existing salt if this is a re-verification
        const existingSalt = await this.db.getSalt(atsurUuid).catch(() => null);

        // 2. Build the commitment (provider-agnostic)
        const result = IdentityCommitmentService.buildCommitment(
            providerName,
            providerResponse,
            atsurUuid,
            existingSalt
        );

        if (!result.success) {
            return { success: false, reason: result.reason, actorId: null };
        }

        const { actorId, commitment, salt, backendRecord } = result;
        const actorTypeIndex = ACTOR_TYPE_MAP[cidocActorType];
        if (actorTypeIndex === undefined) {
            throw new Error(`Unknown CIDOC actor type: ${cidocActorType}`);
        }

        // 3. Check if actor already exists on-chain (provider switch / re-verify scenario)
        const alreadyExists = await this.registry.actorExists(actorId);

        if (alreadyExists) {
            const tx = await this.registry.updateKycCommitment(actorId, commitment, providerName);
            await tx.wait();
            await this.db.saveActorRecord({ ...backendRecord, onChainTx: tx.hash, event: "kyc_updated" });
            return { success: true, event: "kyc_updated", actorId, txHash: tx.hash, provider: providerName };
        }

        // 4. First-time registration — save salt BEFORE the on-chain call
        //    (if the tx fails, salt is still safe in the DB)
        await this.db.saveSalt(atsurUuid, salt);

        const tx = await this.registry.registerActor(
            actorId,
            actorTypeIndex,
            commitment,
            providerName,
            custodialWallet
        );
        await tx.wait();

        await this.db.saveActorRecord({ ...backendRecord, onChainTx: tx.hash, event: "actor_registered" });

        return {
            success:  true,
            event:    "actor_registered",
            actorId,
            txHash:   tx.hash,
            provider: providerName,
        };
    }

    // ─────────────────────────────────────────────
    // WALLET LINKING — Biconomy → MetaMask
    // ─────────────────────────────────────────────

    /**
     * Link a user's self-custodial wallet to their existing actor record.
     * One transaction (~55K gas on Lisk L2). All historical provenance stays
     * valid via actorId — nothing is migrated.
     *
     * @param {string} atsurUuid  Platform UUID (used to derive actorId)
     * @param {string} newWallet  MetaMask (or any self-custodial) wallet address
     * @returns {Promise<object>}
     */
    async linkSelfCustodialWallet(atsurUuid, newWallet) {
        const actorId = IdentityCommitmentService.deriveActorId(atsurUuid);

        // Fetch the custodial wallet from on-chain to build the commitment
        const actor          = await this.registry.getActor(actorId);
        const custodialWallet = actor.custodialWallet;

        // Random nonce — prevents replay attacks
        const nonce = "0x" + crypto.randomBytes(32).toString("hex");

        const linkCommitment = IdentityCommitmentService.buildWalletLinkCommitment(
            actorId,
            custodialWallet,
            newWallet,
            nonce
        );

        const tx = await this.registry.linkSelfCustodialWallet(
            actorId,
            newWallet,
            nonce,
            linkCommitment
        );
        await tx.wait();

        return {
            success:             true,
            actorId,
            custodialWallet,
            selfCustodialWallet: newWallet,
            linkCommitment,
            txHash:              tx.hash,
        };
    }

    // ─────────────────────────────────────────────
    // INSTITUTION VERIFIER DELEGATION
    // ─────────────────────────────────────────────

    /**
     * Delegate a verifier into an institution's pool.
     * Called when e.g. NGA adds a student verifier to their office.
     *
     * NOTE: If trainingCertified = false, the contract emits VerifierTrainingPending.
     *       Your backend should listen for this event and trigger the Atsur training
     *       course flow. Call certifyVerifierTraining() once the course is completed.
     *       TODO: Wire to Atsur training course completion webhook.
     *
     * @param {string}  institutionUuid    Institution's Atsur UUID (NGA, gallery, etc.)
     * @param {string}  verifierUuid       Verifier's Atsur internal UUID
     * @param {boolean} trainingCertified  Has the verifier already completed Atsur training?
     * @param {number}  certifiedAt        Unix timestamp of certification (0 if not yet)
     * @returns {Promise<object>}
     */
    async delegateVerifier(institutionUuid, verifierUuid, trainingCertified = false, certifiedAt = 0) {
        const { verifierId, institutionActorId } =
            IdentityCommitmentService.buildVerifierId(verifierUuid, institutionUuid);

        const tx = await this.registry.delegateVerifier(
            institutionActorId,
            verifierId,
            trainingCertified,
            certifiedAt
        );
        await tx.wait();

        return { success: true, institutionActorId, verifierId, trainingCertified, txHash: tx.hash };
    }

    /**
     * Certify that a verifier has completed Atsur's training course.
     * Only OPERATOR_ROLE or DEFAULT_ADMIN_ROLE can call this.
     * Institutions cannot self-certify their verifiers.
     *
     * TODO: Wire this to a training course completion webhook from your LMS.
     *       Example: POST /webhooks/training-complete → { verifierUuid, institutionUuid }
     *
     * @param {string} institutionUuid
     * @param {string} verifierUuid
     * @returns {Promise<object>}
     */
    async certifyVerifierTraining(institutionUuid, verifierUuid) {
        const { verifierId, institutionActorId } =
            IdentityCommitmentService.buildVerifierId(verifierUuid, institutionUuid);

        const tx = await this.registry.certifyVerifierTraining(institutionActorId, verifierId);
        await tx.wait();

        return {
            success:          true,
            institutionActorId,
            verifierId,
            certifiedAt:      Math.floor(Date.now() / 1000),
            txHash:           tx.hash,
        };
    }

    /**
     * Revoke a verifier.
     * Can be called by institution OR Atsur operator (platform override).
     * IMPORTANT: Immediately invalidate the verifier's DB session BEFORE waiting
     * for on-chain confirmation, to prevent in-flight abuse.
     *
     * @param {string} institutionUuid
     * @param {string} verifierUuid
     * @returns {Promise<object>}
     */
    async revokeVerifier(institutionUuid, verifierUuid) {
        const { verifierId, institutionActorId } =
            IdentityCommitmentService.buildVerifierId(verifierUuid, institutionUuid);

        const tx = await this.registry.revokeVerifier(institutionActorId, verifierId);
        await tx.wait();

        return { success: true, institutionActorId, verifierId, txHash: tx.hash };
    }

    // ─────────────────────────────────────────────
    // ACTOR STATUS MANAGEMENT
    // ─────────────────────────────────────────────

    async suspendActor(atsurUuid) {
        const actorId = IdentityCommitmentService.deriveActorId(atsurUuid);
        const tx      = await this.registry.setActorStatus(actorId, ACTOR_STATUS_MAP.Suspended);
        await tx.wait();
        return { success: true, actorId, status: "Suspended", txHash: tx.hash };
    }

    async revokeActor(atsurUuid) {
        const actorId = IdentityCommitmentService.deriveActorId(atsurUuid);
        const tx      = await this.registry.setActorStatus(actorId, ACTOR_STATUS_MAP.Revoked);
        await tx.wait();
        return { success: true, actorId, status: "Revoked", txHash: tx.hash };
    }

    async reinstateActor(atsurUuid) {
        const actorId = IdentityCommitmentService.deriveActorId(atsurUuid);
        const tx      = await this.registry.setActorStatus(actorId, ACTOR_STATUS_MAP.Active);
        await tx.wait();
        return { success: true, actorId, status: "Active", txHash: tx.hash };
    }

    // ─────────────────────────────────────────────
    // READ HELPERS
    // ─────────────────────────────────────────────

    /**
     * Check whether a verifier is active AND training-certified.
     * Use before accepting events attested by delegated verifiers.
     */
    async isVerifierCertifiedAndActive(institutionUuid, verifierUuid) {
        const { verifierId, institutionActorId } =
            IdentityCommitmentService.buildVerifierId(verifierUuid, institutionUuid);
        return this.registry.isActiveVerifier(institutionActorId, verifierId);
    }

    /** Derive actorId from UUID without a chain call. */
    static deriveActorId(atsurUuid) {
        return IdentityCommitmentService.deriveActorId(atsurUuid);
    }

    static deriveVerifierId(atsurVerifierUuid) {
        return ethers.keccak256(ethers.toUtf8Bytes(atsurVerifierUuid));
    }
}

module.exports = { ActorRegistryService, ACTOR_TYPE_MAP, ACTOR_STATUS_MAP };
