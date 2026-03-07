/**
 * CidocEventEncoder.js
 *
 * Builds CIDOC-CRM JSON-LD provenance event documents and computes their Merkle leaves.
 *
 * ACTOR REPRESENTATION IN CIDOC EVENTS:
 *   Every actor reference is built via tier1Actor() or tier2Actor().
 *   No personal data (name, DOB, ID number) ever appears in events.
 *   The actorId is the only identity reference — it links to AtsurActorRegistry on-chain.
 *
 * AUTHORSHIP LEAF:
 *   For every E12_Production / E65_Creation event, CidocEventEncoder.computeAuthorshipLeaf()
 *   produces the deterministic leaf that AtsurProvenance.checkAuthorship() can verify.
 *   This MUST be included in the batch's Merkle tree alongside the full CIDOC event leaf.
 *
 * MERKLE LEAF COMPUTATION:
 *   leaf = keccak256(canonical JSON string of the event document)
 *   "Canonical" = keys sorted recursively, no extra whitespace.
 *   This matches the OZ MerkleProof sorted-pair scheme used on-chain.
 *
 * EVENTS SUPPORTED:
 *   E12_Production           — artwork physical creation
 *   E65_Creation             — digital artwork creation
 *   E8_Acquisition           — custody/ownership transfer
 *   E13_Attribute_Assignment — NGA certification / attestation
 *   E11_Modification         — restoration, conservation
 *   E6_Destruction           — recorded destruction
 */

const { ethers }                    = require("ethers");
const { IdentityCommitmentService } = require("./IdentityCommitmentService");

const CIDOC_CONTEXT   = "https://cidoc-crm.org/html/cidoc_crm_v7.1.3.html";
const ATSUR_NAMESPACE = "https://atsur.art/ontology/";

class CidocEventEncoder {

    // ─────────────────────────────────────────────
    // ACTOR REFERENCE BUILDERS
    // ─────────────────────────────────────────────

    /**
     * Build a Tier 1 (KYC verified) actor reference for a CIDOC event.
     *
     * @param {string} actorId     bytes32 actorId from AtsurActorRegistry
     * @param {string} cidocType   "E21_Person" | "E74_Group" | "E40_Legal_Body"
     * @param {string} kycProvider "smile_id" | "persona" | "onfido"
     */
    static tier1Actor(actorId, cidocType, kycProvider) {
        return {
            "@id":                   `atsur:actor/${actorId}`,
            "@type":                 `crm:${cidocType}`,
            "atsur:kycProvider":     kycProvider,
            "atsur:tier":            "KYC_Verified",
            "atsur:registryContract":"AtsurActorRegistry",
        };
    }

    /**
     * Build a Tier 2 (delegated verifier) actor reference.
     * The institution is named; the individual verifier is pseudonymous.
     *
     * @param {string} institutionActorId       bytes32 actorId of the institution
     * @param {string} institutionType          "E40_Legal_Body" | "E74_Group"
     * @param {string} institutionKycProvider   Institution's KYC provider
     * @param {string} verifierId               Opaque bytes32 verifier ID
     */
    static tier2Actor(institutionActorId, institutionType, institutionKycProvider, verifierId) {
        return {
            "@id":               `atsur:actor/${institutionActorId}`,
            "@type":             `crm:${institutionType}`,
            "atsur:kycProvider": institutionKycProvider,
            "atsur:tier":        "KYC_Verified",
            "atsur:verifier": {
                "@id":                   `atsur:verifier/${verifierId}`,
                "@type":                 "atsur:DelegatedVerifier",
                "atsur:tier":            "Delegated",
                "atsur:trainingCertified": true,
                // Verifier personal identity is NOT here.
                // Traceable internally by Atsur via verifierId ↔ UUID mapping in DB.
            },
        };
    }

    // ─────────────────────────────────────────────
    // EVENT BUILDERS
    // ─────────────────────────────────────────────

    /**
     * E12_Production — Physical artwork creation.
     *
     * @param {object} p
     * @param {string} p.artworkId       keccak256(atsur_artwork_uuid)
     * @param {string} p.artworkUuid     Atsur artwork UUID (human reference, not stored on-chain)
     * @param {string} p.artworkTitle    Title of the work
     * @param {string} p.medium          "oil on canvas", "acrylic on board", etc.
     * @param {string} p.dimensions      "120cm × 90cm"
     * @param {string} p.creationDate    ISO8601 date or year
     * @param {string} p.creationPlace   "Lagos, Nigeria"
     * @param {object} p.artist          Result of tier1Actor() for the artist
     * @param {string} p.eventId         Unique event UUID
     */
    static E12_Production(p) {
        return {
            "@context": { "crm": CIDOC_CONTEXT, "atsur": ATSUR_NAMESPACE },
            "@type":    "crm:E12_Production",
            "@id":      `atsur:event/${p.eventId}`,
            "crm:P108_has_produced": {
                "@id":                          `atsur:artwork/${p.artworkId}`,
                "@type":                        "crm:E22_Human-Made_Object",
                "atsur:artworkUuid":            p.artworkUuid,
                "crm:P102_has_title":           p.artworkTitle,
                "crm:P45_consists_of":          p.medium,
                "crm:P43_has_dimension":        p.dimensions,
                "atsur:physicalInspectionVerified": true,
            },
            "crm:P14_carried_out_by": p.artist,
            "crm:P4_has_time-span": {
                "@type":                       "crm:E52_Time-Span",
                "crm:P82a_begin_of_the_begin": p.creationDate,
                "crm:P82b_end_of_the_end":     p.creationDate,
            },
            "crm:P7_took_place_at": {
                "@type":                    "crm:E53_Place",
                "crm:P87_is_identified_by": p.creationPlace,
            },
            "atsur:recordedAt":    new Date().toISOString(),
            "atsur:schemaVersion": "1.0",
        };
    }

    /**
     * E65_Creation — Digital artwork creation.
     * Extends E12_Production with IPFS CID and file hash fields.
     *
     * @param {object} p         Same as E12_Production params, plus:
     * @param {string} [p.ipfsCid]   IPFS content ID of the digital file (optional)
     * @param {string} [p.fileHash]  SHA-256 of the digital file (optional)
     */
    static E65_Creation(p) {
        const base = CidocEventEncoder.E12_Production(p);
        base["@type"]                  = "crm:E65_Creation";
        base["atsur:digitalAssetCid"]  = p.ipfsCid   ?? null;
        base["atsur:fileHash"]         = p.fileHash  ?? null;
        return base;
    }

    /**
     * E8_Acquisition — Custody / ownership transfer.
     * Used for sales, loans, gifts, exports, bequests.
     *
     * @param {object} p
     * @param {string} p.artworkId
     * @param {object} p.fromActor        tier1Actor() or tier2Actor() reference
     * @param {object} p.toActor          tier1Actor() or tier2Actor() reference
     * @param {object} p.attestor         Who certified this transfer
     * @param {string} p.transferType     "sale" | "loan" | "gift" | "export" | "bequest"
     * @param {string} p.transferDate     ISO8601
     * @param {string} p.eventId
     * @param {string} [p.permitReference] NGA Travel Permit number if applicable
     */
    static E8_Acquisition(p) {
        return {
            "@context": { "crm": CIDOC_CONTEXT, "atsur": ATSUR_NAMESPACE },
            "@type":    "crm:E8_Acquisition",
            "@id":      `atsur:event/${p.eventId}`,
            "crm:P24_transferred_title_of": {
                "@id":   `atsur:artwork/${p.artworkId}`,
                "@type": "crm:E22_Human-Made_Object",
            },
            "crm:P23_transferred_title_from": p.fromActor,
            "crm:P22_transferred_title_to":   p.toActor,
            "crm:P14_carried_out_by":         p.attestor,
            "atsur:transferType":             p.transferType,
            "crm:P4_has_time-span": {
                "@type":                       "crm:E52_Time-Span",
                "crm:P82a_begin_of_the_begin": p.transferDate,
            },
            ...(p.permitReference ? {
                "atsur:ngaTravelPermit":       p.permitReference,
                "atsur:ngaCertificateVerified": true,
            } : {}),
            "atsur:recordedAt":    new Date().toISOString(),
            "atsur:schemaVersion": "1.0",
        };
    }

    /**
     * E13_Attribute_Assignment — NGA Certification / Attestation.
     * Used for Certificates of Authenticity and Travel Permits.
     * Does NOT transfer custody — records institutional attestation only.
     *
     * @param {object} p
     * @param {string} p.artworkId
     * @param {object} p.attestor           tier1Actor() or tier2Actor()
     * @param {string} p.certificateNumber  NGA reference number
     * @param {string} p.certificateType    "CoA" | "TravelPermit"
     * @param {string} p.certificationDate  ISO8601
     * @param {string} p.eventId
     */
    static E13_AttributeAssignment(p) {
        return {
            "@context": { "crm": CIDOC_CONTEXT, "atsur": ATSUR_NAMESPACE },
            "@type":    "crm:E13_Attribute_Assignment",
            "@id":      `atsur:event/${p.eventId}`,
            "crm:P140_assigned_attribute_to": {
                "@id":   `atsur:artwork/${p.artworkId}`,
                "@type": "crm:E22_Human-Made_Object",
            },
            "crm:P14_carried_out_by": p.attestor,
            "crm:P141_assigned": {
                "@type":                    "crm:E55_Type",
                "crm:P1_is_identified_by":  "Authenticated",
            },
            "atsur:certificateType":   p.certificateType,
            "atsur:certificateNumber": p.certificateNumber,
            "atsur:issuingAuthority":  "National Gallery of Art Nigeria",
            "crm:P4_has_time-span": {
                "@type":                       "crm:E52_Time-Span",
                "crm:P82a_begin_of_the_begin": p.certificationDate,
            },
            "atsur:recordedAt":    new Date().toISOString(),
            "atsur:schemaVersion": "1.0",
        };
    }

    /**
     * E11_Modification — Restoration or conservation work.
     *
     * @param {object} p
     * @param {string} p.artworkId
     * @param {object} p.conservator      tier1Actor() reference
     * @param {string} p.modificationType "restoration" | "conservation" | "cleaning"
     * @param {string} p.modificationDate ISO8601
     * @param {string} p.description      Free-text description of work performed
     * @param {string} p.eventId
     */
    static E11_Modification(p) {
        return {
            "@context": { "crm": CIDOC_CONTEXT, "atsur": ATSUR_NAMESPACE },
            "@type":    "crm:E11_Modification",
            "@id":      `atsur:event/${p.eventId}`,
            "crm:P31_has_modified": {
                "@id":   `atsur:artwork/${p.artworkId}`,
                "@type": "crm:E22_Human-Made_Object",
            },
            "crm:P14_carried_out_by":      p.conservator,
            "atsur:modificationType":      p.modificationType,
            "atsur:modificationDescription": p.description ?? null,
            "crm:P4_has_time-span": {
                "@type":                       "crm:E52_Time-Span",
                "crm:P82a_begin_of_the_begin": p.modificationDate,
            },
            "atsur:recordedAt":    new Date().toISOString(),
            "atsur:schemaVersion": "1.0",
        };
    }

    /**
     * E6_Destruction — Recorded destruction of an artwork.
     *
     * @param {object} p
     * @param {string} p.artworkId
     * @param {string} p.destructionDate  ISO8601
     * @param {string} p.destructionCause "fire" | "natural_disaster" | "deliberate" | "unknown"
     * @param {object} p.attestor         tier1Actor() or tier2Actor()
     * @param {string} p.eventId
     */
    static E6_Destruction(p) {
        return {
            "@context": { "crm": CIDOC_CONTEXT, "atsur": ATSUR_NAMESPACE },
            "@type":    "crm:E6_Destruction",
            "@id":      `atsur:event/${p.eventId}`,
            "crm:P13_destroyed": {
                "@id":   `atsur:artwork/${p.artworkId}`,
                "@type": "crm:E22_Human-Made_Object",
            },
            "crm:P14_carried_out_by":   p.attestor,
            "atsur:destructionCause":   p.destructionCause,
            "crm:P4_has_time-span": {
                "@type":                       "crm:E52_Time-Span",
                "crm:P82a_begin_of_the_begin": p.destructionDate,
            },
            "atsur:recordedAt":    new Date().toISOString(),
            "atsur:schemaVersion": "1.0",
        };
    }

    // ─────────────────────────────────────────────
    // MERKLE LEAF COMPUTATION
    // ─────────────────────────────────────────────

    /**
     * Compute the Merkle leaf for a CIDOC event document.
     * leaf = keccak256(canonical JSON string of event)
     * "Canonical" = top-level keys sorted alphabetically, no extra whitespace.
     *
     * @param {object} eventDocument
     * @returns {string} bytes32 hex leaf
     */
    static computeEventLeaf(eventDocument) {
        const canonical = JSON.stringify(eventDocument, Object.keys(eventDocument).sort());
        return ethers.keccak256(ethers.toUtf8Bytes(canonical));
    }

    /**
     * Compute the deterministic authorship leaf for an artwork creation event.
     * This MUST be included in every E12_Production / E65_Creation batch.
     * AtsurProvenance.checkAuthorship() verifies against this leaf.
     *
     * @param {string} artworkId       keccak256(atsur_artwork_uuid)
     * @param {string} creatorActorId  actorId of the artist
     * @returns {string} bytes32 hex leaf
     */
    static computeAuthorshipLeaf(artworkId, creatorActorId) {
        return IdentityCommitmentService.computeAuthorshipLeaf(artworkId, creatorActorId);
    }

    /**
     * Build all leaves for a creation event batch entry.
     * Returns both the full CIDOC event leaf and the authorship leaf.
     * Both MUST be included in the Merkle tree.
     *
     * @param {object} eventDocument  Output of E12_Production() or E65_Creation()
     * @param {string} artworkId      keccak256(atsur_artwork_uuid)
     * @param {string} creatorActorId actorId of the artist
     * @returns {{ eventLeaf: string, authorshipLeaf: string }}
     */
    static buildCreationLeaves(eventDocument, artworkId, creatorActorId) {
        return {
            eventLeaf:      CidocEventEncoder.computeEventLeaf(eventDocument),
            authorshipLeaf: CidocEventEncoder.computeAuthorshipLeaf(artworkId, creatorActorId),
        };
    }
}

module.exports = { CidocEventEncoder, CIDOC_CONTEXT, ATSUR_NAMESPACE };
