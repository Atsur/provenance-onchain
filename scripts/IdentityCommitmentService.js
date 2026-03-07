/**
 * IdentityCommitmentService.js
 *
 * Provider-agnostic KYC commitment builder for AtsurActorRegistry.
 *
 * ARCHITECTURE:
 * - Atsur platform UUID is the canonical identity anchor.
 * - actorId  = keccak256(atsurUuid)
 * - commitment = keccak256(abi.encodePacked(providerName, providerUserId, atsurUuid, salt))
 * - Salt is generated ONCE per actor, stored encrypted in your backend, NEVER on-chain.
 * - providerName is revealed on-chain ("smile_id") — satisfies the
 *   "prove provider confirmed them, reveal provider name only" ZK level.
 *
 * SWITCHING PROVIDERS (global expansion):
 * - Add a new adapter to PROVIDER_ADAPTERS below.
 * - Call updateKycCommitment() on-chain with new commitment + new provider name.
 * - actorId stays the same; event log preserves full verification history.
 *
 * PROVIDERS SUPPORTED:
 *   smile_id — Biometric KYC / SmartSelfie (Nigeria launch)
 *   stub     — Testing / new provider integration placeholder
 */

const { ethers } = require("ethers");
const crypto     = require("crypto");

// ─────────────────────────────────────────────
// PROVIDER ADAPTERS
// Each adapter normalises provider-specific response shapes
// into a standard AtsurKycResult. Add new providers here.
// ─────────────────────────────────────────────

const PROVIDER_ADAPTERS = {

    /**
     * Smile ID — Biometric KYC / SmartSelfie / ID Verification
     * Docs: https://docs.usesmileid.com/
     * Callback fields: job_success, result.ResultCode, result.SmileJobID,
     *                  result.PartnerParams.user_id, result.ConfidenceValue
     */
    smile_id: {
        name: "smile_id",
        normalise(response) {
            if (!response.job_success) {
                return {
                    verified: false,
                    reason:   response.result?.ResultText || "job_failed",
                };
            }
            // ResultCode 0810 = Enrolled, 0811 = Authenticated,
            // 1020 = ID Verified,           1012 = Processed
            const approvedCodes = ["0810", "0811", "1020", "1012"];
            const code = String(response.result?.ResultCode ?? "");
            if (!approvedCodes.includes(code)) {
                return { verified: false, reason: `rejected_code_${code}` };
            }
            return {
                verified:        true,
                providerUserId:  response.result?.PartnerParams?.user_id,
                providerJobId:   response.result?.SmileJobID,
                confidenceScore: Number(response.result?.ConfidenceValue ?? 0),
                country:         response.result?.Country ?? null,
                idType:          response.result?.IDType  ?? null,
                verifiedAt:      new Date().toISOString(),
            };
        },
    },

    /**
     * Stub adapter — for testing or bootstrapping a new provider integration.
     * Accepts any response and always returns verified = true.
     * Replace with a real adapter before using in production.
     */
    stub: {
        name: "stub",
        normalise(response) {
            return {
                verified:        true,
                providerUserId:  response.userId  ?? `stub_${Date.now()}`,
                providerJobId:   response.jobId   ?? "stub_job",
                confidenceScore: 100,
                country:         response.country ?? null,
                idType:          null,
                verifiedAt:      new Date().toISOString(),
            };
        },
    },

    /*
     * ─────────────────────────────────────────────
     * FUTURE PROVIDERS — uncomment and complete when expanding:
     *
     * persona: {                 // Europe / international expansion
     *   name: "persona",
     *   normalise(response) {
     *     const status = response.data?.attributes?.status;
     *     if (status !== "completed") return { verified: false, reason: `status_${status}` };
     *     return {
     *       verified:       true,
     *       providerUserId: response.data?.id,
     *       providerJobId:  response.data?.id,
     *       country:        response.data?.attributes?.fields?.["country-code"]?.value ?? null,
     *       idType:         response.data?.attributes?.fields?.["id-class"]?.value      ?? null,
     *       verifiedAt:     new Date().toISOString(),
     *     };
     *   },
     * },
     *
     * onfido: {                  // UK / Europe expansion
     *   name: "onfido",
     *   normalise(response) {
     *     if (response.status !== "complete" || response.result !== "clear") {
     *       return { verified: false, reason: `result_${response.result}` };
     *     }
     *     return {
     *       verified:       true,
     *       providerUserId: response.applicant_id,
     *       providerJobId:  response.id,
     *       country:        null,
     *       idType:         null,
     *       verifiedAt:     new Date().toISOString(),
     *     };
     *   },
     * },
     * ─────────────────────────────────────────────
     */
};

// ─────────────────────────────────────────────
// IDENTITY COMMITMENT SERVICE
// ─────────────────────────────────────────────

class IdentityCommitmentService {

    /**
     * Process a KYC callback from any supported provider and build the on-chain commitment.
     *
     * @param {string}  providerName     "smile_id" | "stub"
     * @param {object}  providerResponse Raw callback payload from the provider
     * @param {string}  atsurUuid        Your stable platform UUID for this user
     * @param {string}  [existingSalt]   Provide the existing salt when RE-verifying
     *                                   (keeps commitment stable). Null for first-time.
     * @returns {object} CommitmentResult
     */
    static buildCommitment(providerName, providerResponse, atsurUuid, existingSalt = null) {
        const adapter = PROVIDER_ADAPTERS[providerName];
        if (!adapter) {
            throw new Error(
                `Unknown KYC provider: "${providerName}". ` +
                `Add an adapter to PROVIDER_ADAPTERS first.`
            );
        }

        const normalised = adapter.normalise(providerResponse);

        if (!normalised.verified) {
            return {
                success:    false,
                reason:     normalised.reason,
                actorId:    null,
                commitment: null,
                salt:       null,
            };
        }

        if (!normalised.providerUserId) {
            return {
                success: false,
                reason:  "missing_provider_user_id",
                actorId: null,
                commitment: null,
                salt:    null,
            };
        }

        // Salt: generate ONCE per actor, store encrypted in backend, never change.
        // Re-verification with a new provider MUST use the SAME salt so actorId
        // and commitment remain stable.
        const salt = existingSalt || ("0x" + crypto.randomBytes(32).toString("hex"));

        // actorId = keccak256(atsurUuid) — stable canonical identity
        const actorId = ethers.keccak256(ethers.toUtf8Bytes(atsurUuid));

        // commitment = keccak256(abi.encodePacked(providerName, providerUserId, atsurUuid, salt))
        // Must match the on-chain computation in AtsurActorRegistry.verifyKycCommitment().
        const commitment = ethers.keccak256(
            ethers.solidityPacked(
                ["string", "string", "string", "bytes32"],
                [providerName, normalised.providerUserId, atsurUuid, salt]
            )
        );

        return {
            success:         true,
            actorId,           // Store as actorId in contract calls
            commitment,        // Store on-chain via registerActor() or updateKycCommitment()
            salt,              // CRITICAL: store encrypted in backend. Never expose publicly.
            providerName,
            providerUserId:  normalised.providerUserId,
            providerJobId:   normalised.providerJobId,
            confidenceScore: normalised.confidenceScore ?? null,
            country:         normalised.country,
            idType:          normalised.idType,
            verifiedAt:      normalised.verifiedAt,
            // What to store in your backend DB alongside the on-chain commitment:
            backendRecord: {
                atsurUuid,
                actorId,
                providerName,
                providerUserId: normalised.providerUserId,
                providerJobId:  normalised.providerJobId,
                salt,           // Encrypt at rest (AWS KMS, HashiCorp Vault, etc.)
                commitment,
                verifiedAt:     normalised.verifiedAt,
                country:        normalised.country,
                idType:         normalised.idType,
            },
        };
    }

    /**
     * Build a verifier ID for a Tier 2 delegated verifier.
     * Verifiers are pseudonymous on-chain — only the opaque verifierId is stored.
     *
     * @param {string} atsurVerifierUuid  Atsur's internal UUID for this verifier
     * @param {string} institutionUuid    The delegating institution's Atsur UUID
     * @returns {{ verifierId: string, institutionActorId: string }}
     */
    static buildVerifierId(atsurVerifierUuid, institutionUuid) {
        return {
            verifierId:         ethers.keccak256(ethers.toUtf8Bytes(atsurVerifierUuid)),
            institutionActorId: ethers.keccak256(ethers.toUtf8Bytes(institutionUuid)),
        };
    }

    /**
     * Build the wallet link commitment before calling linkSelfCustodialWallet().
     * Must match the on-chain computation in AtsurActorRegistry.linkSelfCustodialWallet().
     *
     * @param {string} actorId          bytes32 actorId
     * @param {string} custodialWallet  Biconomy wallet address
     * @param {string} newWallet        MetaMask wallet address
     * @param {string} nonce            Random bytes32 nonce from backend
     * @returns {string} linkCommitment — bytes32 to pass to contract
     */
    static buildWalletLinkCommitment(actorId, custodialWallet, newWallet, nonce) {
        return ethers.keccak256(
            ethers.solidityPacked(
                ["bytes32", "address", "address", "bytes32"],
                [actorId, custodialWallet, newWallet, nonce]
            )
        );
    }

    /**
     * Verify a KYC commitment locally.
     * Mirrors the on-chain AtsurActorRegistry.verifyKycCommitment() view function.
     * Useful for off-chain pre-validation before making contract calls.
     *
     * @param {string} providerName    e.g. "smile_id"
     * @param {string} providerUserId
     * @param {string} atsurUuid
     * @param {string} salt            The secret salt stored in backend
     * @param {string} storedCommitment The commitment stored on-chain
     * @returns {boolean}
     */
    static verifyCommitment(providerName, providerUserId, atsurUuid, salt, storedCommitment) {
        const computed = ethers.keccak256(
            ethers.solidityPacked(
                ["string", "string", "string", "bytes32"],
                [providerName, providerUserId, atsurUuid, salt]
            )
        );
        return computed === storedCommitment;
    }

    /**
     * Derive actorId from a UUID without hitting the chain.
     * Useful for building provenance events off-chain.
     *
     * @param {string} atsurUuid
     * @returns {string} actorId (bytes32 hex string)
     */
    static deriveActorId(atsurUuid) {
        return ethers.keccak256(ethers.toUtf8Bytes(atsurUuid));
    }

    /**
     * Compute the deterministic authorship leaf for an artwork creation event.
     * The backend MUST include this leaf in every E12_Production / E65_Creation batch.
     * AtsurProvenance.checkAuthorship() uses this leaf to verify on-chain.
     *
     * @param {string} artworkId       keccak256(atsur_artwork_uuid)
     * @param {string} creatorActorId  actorId of the artist
     * @returns {string} leaf (bytes32 hex string)
     */
    static computeAuthorshipLeaf(artworkId, creatorActorId) {
        // Must match AtsurProvenance.AUTHORSHIP_LEAF_PREFIX = keccak256("ATSUR_AUTHORSHIP_V1")
        const prefix = ethers.keccak256(ethers.toUtf8Bytes("ATSUR_AUTHORSHIP_V1"));
        return ethers.keccak256(
            ethers.solidityPacked(
                ["bytes32", "bytes32", "bytes32"],
                [prefix, artworkId, creatorActorId]
            )
        );
    }
}

module.exports = { IdentityCommitmentService, PROVIDER_ADAPTERS };
