# Implementation Checklist: Align ProvenanceHub with Atsur Whitepaper (Arweave)

Use this with `docs/ATSUR_WHITEPAPER_GAP_ANALYSIS.md`. **Arweave is retained as the primary storage backend** (already configured). Each item is a concrete change.

---

## Contract: `ProvenanceHub.sol`

### 1. Storage / batch reference (Arweave + event type)

- [x] **Add to `BatchCommit`:**
  - `string eventType` — primary CIDOC class (e.g. `"E12_Production"`).
- [x] **Keep:** `arweaveTxId` as the primary archive reference (no IPFS).
- [x] **Duplicate prevention:** Already present (`usedMerkleRoots`, `usedArweaveTxIds`).

### 2. Anchor function (spec-compliant)

- [x] **Add:** `anchorBatch(bytes32 merkleRoot, bytes32 arweaveTxId, uint256 eventCount, string calldata eventType)`.
- [x] **Keep:** `commitBatch` as a wrapper that calls `anchorBatch(..., "E12_Production")` for backward compatibility.
- [x] **Event:** Emit `BatchAnchored(uint256 indexed batchIndex, bytes32 merkleRoot, bytes32 arweaveTxId, uint256 eventCount)` in addition to or instead of `BatchCommitted` for spec-compliant indexers.

### 3. Merkle verification (spec naming + calldata)

- [x] **Add:** `function verifyProvenanceEvent(uint256 batchIndex, bytes32 leaf, bytes32[] calldata proofPath) external view returns (bool)` — same sorted-hash logic as whitepaper; use calldata for gas.
- [x] **Keep:** `verifyProofView` for backward compatibility.

### 4. Phase 1 authorship

- [x] **Add:** `function checkAuthorship(bytes32 artworkId, bytes32 commitment, bytes32 presented) external pure returns (bool)` — return `commitment == presented`. Phase 2 can delegate to ZK verifier later.

### 5. Access control (operator alignment)

- [ ] **Optional:** Add `address public atsurOperator` and `onlyAtsur` for anchor, or document that BATCH_COMMITTER_ROLE is the single authorised committer. (Deferred.)

### 6. Natspec and version

- [x] **Update:** Contract notice to mention AtsurProvenance-compatible API; `anchorBatch`, Arweave, `verifyProvenanceEvent`, `checkAuthorship`.
- [x] **Version:** Bump to reflect Atsur 1.0 alignment (e.g. `"1.1.0"` or `"atsur-1.0.0"`).

---

## Off-chain / repo

### 7. Leaf construction (critical for correctness)

- [x] **Document** in `docs/MERKLE_LEAF.md`:
  - `DOMAIN_SEPARATOR = keccak256("atsur.provenance.v1")`
  - `leaf = keccak256(abi.encodePacked(DOMAIN_SEPARATOR, eventTypeBytes, keccak256(cidocEventJson)))`
  - Leaves must be **sorted** before building the tree (same order as OpenZeppelin / whitepaper).
- [ ] **Implement** in batch-publisher: build leaves per above; build tree with sorted pairs; upload batch to Arweave; call `anchorBatch(merkleRoot, arweaveTxId, eventCount, eventType)`.

### 8. Tests

- [x] **anchorBatch / eventType:** Tests that anchor with `eventType` stores and emits `BatchAnchored`.
- [x] **verifyProvenanceEvent:** Test with same proof as `verifyProofView`; both should match.
- [x] **checkAuthorship:** Test `checkAuthorship(id, c, c)` returns true; `checkAuthorship(id, c, d)` returns false.
- [ ] **Fuzz:** Extend fuzz tests to use `anchorBatch` and `eventType` where applicable.

### 9. Deployment and verification

- [ ] **Deploy script:** Use `anchorBatch` when committing; document Arweave TX ID format.
- [ ] **Verification:** Block explorer verification; mention AtsurProvenance-compatible API and Arweave.

### 10. Whitepaper and verification guides

- [ ] **Appendix (contracts.md):** Update to mention `anchorBatch`, `arweaveTxId`, `eventType`, `verifyProvenanceEvent`, `checkAuthorship`. Note: Arweave used instead of IPFS; verifiers fetch batch payload from Arweave by TX ID.

---

## Quick reference: whitepaper vs implementation (Arweave)

| Whitepaper | Implementation | Status |
|------------|-----------------|--------|
| ipfsCidHash | arweaveTxId | Arweave retained |
| eventType in Batch | eventType in BatchCommit | Added |
| anchorBatch(..., eventType) | anchorBatch(..., eventType) | Added |
| BatchAnchored | BatchAnchored(..., arweaveTxId) | Added |
| verifyProvenanceEvent | verifyProvenanceEvent (calldata) | Added |
| checkAuthorship | checkAuthorship | Added |
| atsurOperator | BATCH_COMMITTER_ROLE (doc) | Optional later |

---

## Done when

- [x] Contract has `anchorBatch(merkleRoot, arweaveTxId, eventCount, eventType)` and stores `eventType` per batch.
- [x] `verifyProvenanceEvent(batchIndex, leaf, proofPath)` is implemented and passes tests.
- [x] `checkAuthorship(artworkId, commitment, presented)` is implemented and tested.
- [x] `BatchAnchored` is emitted for spec-compliant indexers.
- [x] Leaf construction and DOMAIN_SEPARATOR documented in `docs/MERKLE_LEAF.md`.
- [ ] Verification guides and appendix reference deployed contract and Arweave TX ID for batch lookup.
