# Atsur Whitepaper vs ProvenanceHub — Gap Analysis & Roadmap

This document compares the Solidity project in this repo to the **Atsur Whitepaper v1** (atsur-whitepaper-1) and outlines how to make it the secure, production-grade on-chain backbone for that spec.

---

## 1. Verdict: Is This the Right Implementation?

**Short answer: Conceptually yes; specification-wise no.** The project implements the same idea (Merkle-batch provenance anchoring, single-operator commits, proof verification) but diverges from the whitepaper in storage backend, data shape, access model, upgradeability, and missing Phase 1 authorship. It is a good foundation but not yet the “AtsurProvenance” described in the whitepaper.

---

## 2. Where the Project Currently Is

### 2.1 What Matches the Whitepaper

| Aspect | Whitepaper | Current (ProvenanceHub) | Match? |
|--------|------------|-------------------------|--------|
| Merkle batch anchoring | Single tx per batch, root on-chain | Same | ✅ |
| Merkle proof verification | Sorted sibling order, `computed < sibling` ordering | OZ `MerkleProof.verify` (sorted pairs) | ✅ |
| Immutable batch records | No modify/delete of batches | Batches are append-only; no delete | ✅ |
| Single authority for commits | `onlyAtsur` / `atsurOperator` | Role-based (`BATCH_COMMITTER_ROLE`) | ⚠️ Different model |
| View verifier | `verifyProvenanceEvent(batchIndex, leaf, proofPath)` | `verifyProofView(batchId, leafHash, proof)` | ✅ Same behaviour |
| Reentrancy protection | Not specified | Custom guard in `commitBatch` | ✅ Good |

So: batching model, Merkle verification semantics, and read-only proof check are aligned. The main gaps are data model, storage reference, access control, upgradeability, and authorship.

### 2.2 Gaps vs Whitepaper

#### A. Storage backend and batch payload reference

- **Whitepaper:** IPFS. Batch payload referenced by **`ipfsCidHash`** = `keccak256(IPFS_CID_string)`. Decoders fetch payload from IPFS and verify `keccak256(CID) == ipfsCidHash`.
- **Current:** Arweave. Batch referenced by **`arweaveTxId`** (bytes32). No hash-of-CID check; Arweave TX ID format is validated instead.

**Impact:** Event type is required for CIDOC semantics and for the specified leaf construction (event type in leaf hash). Missing `eventType` means the on-chain record does not match the whitepaper batch schema or verification steps. **Decision: Arweave is retained as the primary storage backend** (already configured); verification guides and tooling use Arweave TX ID instead of IPFS CID.

#### C. Access control model

- **Whitepaper:** Single `atsurOperator` address; `onlyAtsur` modifier; operator change is an explicit, visible transaction.
- **Current:** OpenZeppelin AccessControl: `DEFAULT_ADMIN_ROLE`, `BATCH_COMMITTER_ROLE`, `PAUSER_ROLE`. No single “operator” address; multiple committers possible.

**Impact:** Operational and security model in the whitepaper is “one operator, one upgrade path”; the current multi-role design is more flexible but does not match the documented contract interface or the “Atsur cannot / Atsur can” guarantees (e.g. who can anchor).

#### D. Upgradeability

- **Whitepaper:** Spec shows a **non-upgradeable** `AtsurProvenance` contract. Upgrades are mentioned as organisational policy (“announced publicly”) but not as a Solidity pattern.
- **Current:** UUPS upgradeable implementation + ERC1967 proxy; `_authorizeUpgrade` restricted to `DEFAULT_ADMIN_ROLE`.

**Impact:** Upgrades add attack surface (implementation swap, storage layout, initializers). The whitepaper’s “records are permanent and independent of Atsur” is easier to reason about with a non-upgradeable core. If you keep upgrades, they should be explicit in the spec and tightly scoped.

#### E. Phase 1 authorship (critical gap)

- **Whitepaper:** `checkAuthorship(artworkId, commitment, presented)` — on-chain check that `commitment == presented` for Phase 1; later delegation to ZK verifier.
- **Current:** No authorship logic in the contract.

**Impact:** Independent verification and institutional flows assume an on-chain authorship commitment check. Without it, the contract cannot serve as the full “AtsurProvenance” backbone for Phase 1.

#### F. Leaf construction and DOMAIN_SEPARATOR

- **Whitepaper:**  
  `leaf = keccak256(DOMAIN_SEPARATOR || cidocEventType || keccak256(encodedCIDOCEvent))`  
  with `DOMAIN_SEPARATOR = keccak256("atsur.provenance.v1")`. Leaves must be sorted before building the tree.
- **Current:** Contract only stores the root and verifies proofs; it does not define or enforce leaf format. Off-chain pipeline must build leaves; tree must use the same sorted convention as OZ (which matches the whitepaper).

**Impact:** Correctness depends entirely on off-chain code. The contract is compatible as long as (1) leaves are built per whitepaper and (2) tree construction uses sorted pairs (as OZ expects). Recommendation: document DOMAIN_SEPARATOR and leaf construction in repo and in any batch-publisher SDK.

#### G. Duplicate prevention

- **Whitepaper:** No explicit duplicate-Merkle-root or duplicate-IPFS-CID rule.
- **Current:** `usedMerkleRoots` and `usedArweaveTxIds` prevent reuse.

**Impact:** Duplicate prevention is a good security improvement; keep it (usedMerkleRoots and usedArweaveTxIds). Arweave retained as primary.

#### H. Batch size limits and pause

- **Whitepaper:** No min/max batch size or pause in the spec.
- **Current:** Configurable `minBatchSize` / `maxBatchSize` and `whenNotPaused` on commits; verification remains callable when paused.

**Impact:** Operational safety and gas/DoS controls; align with whitepaper by either documenting these as operational extensions or making them optional (e.g. 0 = no limit).

#### I. Event naming and ABI

- **Whitepaper:** `BatchAnchored(batchIndex, merkleRoot, ipfsCidHash, eventCount)`.
- **Current:** `BatchCommitted(batchId, merkleRoot, arweaveTxId, eventCount, timestamp, committer)`.

**Impact:** Indexers and verification scripts that expect `BatchAnchored` and `ipfsCidHash` will not work with the current event and params. Aligning names and args improves spec compliance.

---

## 3. How to Get to a Secure, Production-Grade Backbone

### 3.1 Target state (whitepaper-aligned)

1. **Contract name and interface**  
   Offer an **AtsurProvenance**-compatible API: `anchorBatch(merkleRoot, arweaveTxId, eventCount, eventType)` and a `Batch` struct with `merkleRoot`, `arweaveTxId`, `eventCount`, `anchoredAt`, `eventType`. **Arweave is the primary storage backend.**

2. **Storage reference**  
   **Arweave** remains the primary storage. Batch payload is referenced by **`arweaveTxId`** (bytes32). Verifiers fetch the full batch from Arweave by TX ID.

3. **Merkle verification**  
   Keep the same sorted Merkle logic (current OZ usage is compatible with whitepaper). Expose a function named **`verifyProvenanceEvent(batchIndex, leaf, proofPath)`** with `calldata` proof to match the spec.

4. **Authorship**  
   Add **`checkAuthorship(artworkId, commitment, presented)`** returning `(commitment == presented)` for Phase 1. Plan for a separate Phase 2 ZK verifier and a future upgrade or delegation from this function.

5. **Access control**  
   Either:  
   - **Option A (strict spec):** Single `atsurOperator` address, no roles, no upgrade.  
   - **Option B (practical):** Keep roles (e.g. committer, pauser, admin) but add an **`atsurOperator`** address that is the only one allowed to call `anchorBatch` (or map `BATCH_COMMITTER_ROLE` to that single address), and document this in the whitepaper.

6. **Upgradeability**  
   - If the whitepaper stays “no upgrades”: deploy a **non-upgradeable** AtsurProvenance and treat it as immutable.  
   - If you keep upgrades: use a clear versioning and upgrade policy, and consider making the **authorship/verifier** logic the only upgradeable part (e.g. delegate to a separate verifier contract) so batch storage stays immutable.

7. **Security hardening**  
   - Keep duplicate-root (and duplicate-ipfsCidHash) checks.  
   - Optional batch size limits and pause: document as operational extensions.  
   - Use `calldata` for proof arrays in verification.  
   - Consider formal verification or a professional audit for the core anchor and verify paths.

### 3.2 Suggested implementation order

| Step | Action | Purpose |
|------|--------|--------|
| 1 | Add eventType to batch; add anchorBatch(..., eventType); emit BatchAnchored (Arweave retained) | Spec-compliant ABI and events |
| 2 | Add anchorBatch(..., eventType); emit BatchAnchored with arweaveTxId | Spec-compliant events |
| 3 | Add `checkAuthorship(artworkId, commitment, presented)` | Phase 1 completeness |
| 4 | Expose `verifyProvenanceEvent(batchIndex, leaf, proofPath)` (and keep existing view if desired) | Spec-compliant verification API |
| 5 | Decide operator vs roles: single `atsurOperator` or single committer mapped to operator | Match documented “Atsur can / cannot” |
| 6 | Document leaf construction (DOMAIN_SEPARATOR, eventType, keccak(cidocEvent)) and sorted tree | Safe off-chain pipeline |
| 7 | Optional: non-upgradeable or delegate-only upgrades | Clear immutability story |
| 8 | Audit and verification scripts (Arweave TX ID) | Production-grade assurance |

---

## 4. Concrete Improvements (Summary)

### 4.1 Must-have for whitepaper compliance

- **Arweave as primary:** Keep `arweaveTxId`; add `eventType` to batch; function `anchorBatch(merkleRoot, arweaveTxId, eventCount, eventType)`.
- **Event:** `BatchAnchored(batchIndex, merkleRoot, arweaveTxId, eventCount)` (and optionally timestamp/block).
- **Verifier:** `verifyProvenanceEvent(uint256 batchIndex, bytes32 leaf, bytes32[] calldata proofPath)` with the same sorted-hash logic as now.
- **Authorship:** `checkAuthorship(bytes32 artworkId, bytes32 commitment, bytes32 presented)` returning `commitment == presented`.
- **Operator:** Either a single `atsurOperator` for `anchorBatch` or a strict one-address committer role; document in whitepaper.

### 4.2 Should-have for production

- **Duplicate root/TX ID:** Already present (usedMerkleRoots, usedArweaveTxIds).
- **Leaf construction doc:** Explicit DOMAIN_SEPARATOR and formula in repo and SDK so every batch matches the whitepaper.
- **Tests:** Add tests that build leaves per whitepaper formula and verify via `verifyProvenanceEvent`; test `checkAuthorship` for Phase 1.
- **Gas:** Use `calldata` for `proofPath` in the main verification function to save gas.

### 4.3 Nice-to-have

- **Batch size limits:** Keep as configurable (or 0 = disabled) and document as operational policy.
- **Pause:** Keep for emergency stop of new commits; document that verification stays available when paused.
- **Version / network:** `version()` and chain id in events or metadata for multi-chain and upgrade tracking.
- **Phase 2:** Separate `AuthorshipVerifier` contract and a way for `checkAuthorship` to delegate to it (upgrade or configurable address) without changing the main anchor storage.

---

## 5. Summary Table

| Dimension | Whitepaper | Current | Action |
|-----------|------------|--------|--------|
| Contract name | AtsurProvenance | ProvenanceHub | Align name/ABI |
| Storage ref | IPFS in spec; we use Arweave | Arweave + arweaveTxId | Keep Arweave; add eventType |
| Batch struct | merkleRoot, ipfsCidHash, eventCount, anchoredAt, eventType | merkleRoot, arweaveTxId, timestamp, eventCount, blockNumber | Add eventType; keep arweaveTxId |
| Anchor function | anchorBatch(..., eventType) | commitBatch(..., no eventType) | Rename, add eventType |
| Verification | verifyProvenanceEvent(batchIndex, leaf, proofPath) | verifyProofView(batchId, leafHash, proof) | Add spec-named function; use calldata |
| Authorship | checkAuthorship(artworkId, commitment, presented) | — | Implement |
| Access | atsurOperator only | BATCH_COMMITTER_ROLE, etc. | Single operator or document role mapping |
| Upgrade | Not in spec | UUPS | Decide: non-upgradeable or documented upgrade policy |
| Merkle/leaf | Sorted, DOMAIN_SEPARATOR + eventType + hash | Not in contract | Document and test off-chain |
| Events | BatchAnchored | BatchCommitted | Emit BatchAnchored with arweaveTxId |

---

## 6. Conclusion

The current Solidity project is a solid Merkle-batch provenance anchor with good security habits (reentrancy guard, duplicate prevention, roles, pause) and verification logic that matches the whitepaper’s Merkle semantics. It is **not** yet the exact “AtsurProvenance” from the whitepaper because of missing `eventType`, missing `checkAuthorship`, different access and naming, and upgradeability.

To become the **secure, production-grade backbone** for the whitepaper:

1. Add **`eventType`** and **`anchorBatch(merkleRoot, arweaveTxId, eventCount, eventType)`**; emit **`BatchAnchored`** with `arweaveTxId` (Arweave retained).
2. Align **verification API** (**`verifyProvenanceEvent`**) and implement **Phase 1 `checkAuthorship`**; plan for Phase 2 ZK delegation.
3. **Document** leaf construction and DOMAIN_SEPARATOR; add tests that match the whitepaper verification flow.
4. Fix **access control** to a single operator or a clearly documented single-committer model.
5. Decide **upgrade policy** (immutable core vs delegate-only upgrades) and document it.

After these steps, the project will match the whitepaper’s on-chain specification and support the documented independent verification and institutional verification flows.
