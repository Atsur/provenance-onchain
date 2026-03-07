# Merkle Leaf Construction (Atsur Provenance)

This document defines how provenance event leaves are hashed for the Merkle tree used in ProvenanceHub. The same construction must be used off-chain when building batches so that proofs verify on-chain.

---

## Domain separator

To avoid cross-system proof reuse, all leaves are bound to the Atsur provenance domain:

```
DOMAIN_SEPARATOR = keccak256("atsur.provenance.v1")
```

Use the UTF-8 bytes of the string `atsur.provenance.v1`, then keccak256.

---

## Leaf hash formula

For each CIDOC event in a batch:

1. Encode the event as JSON (canonical or deterministic stringification).
2. Compute:
   - `eventHash = keccak256(encodedCIDOCEventJSON)`
   - `eventTypeBytes = bytes(eventType)` — the primary CIDOC class (e.g. `E12_Production`, `E8_Acquisition`).
3. Compute the leaf:
   ```
   leaf = keccak256(abi.encodePacked(
       DOMAIN_SEPARATOR,
       eventTypeBytes,
       eventHash
   ))
   ```

In pseudocode:

```
leaf = keccak256(DOMAIN_SEPARATOR || eventTypeBytes || keccak256(cidocEventJSON))
```

---

## Tree construction

- **Order:** Leaves must be **sorted** (e.g. by leaf hash as bytes32) before building the tree.
- **Parent hash:** Same as the contract and OpenZeppelin’s MerkleProof (sorted sibling order):
  ```
  parent = keccak256(abi.encodePacked(leftChild, rightChild))
  ```
  where the smaller of the two hashes (as bytes32) is first. So: `leftChild < rightChild ? (leftChild, rightChild) : (rightChild, leftChild)`.

This matches the on-chain verification in `verifyProvenanceEvent`, which uses:

```solidity
computed = computed < sibling
    ? keccak256(abi.encodePacked(computed, sibling))
    : keccak256(abi.encodePacked(sibling, computed));
```

---

## Proof path

For each leaf, the **proof path** is the sequence of sibling hashes from the leaf up to the root (in order). The contract expects this path in `verifyProvenanceEvent(batchIndex, leaf, proofPath)` and in `verifyProofView(batchId, leafHash, proof)` — both use the same sorted ordering.

When building the tree off-chain (e.g. with [@openzeppelin/merkle-tree](https://www.npmjs.com/package/@openzeppelin/merkle-tree)), use **sortPairs: true** so generated proofs match the contract.

---

## Event types (CIDOC classes)

Common values for `eventType`:

| Value | Meaning |
|-------|--------|
| `E12_Production` | Initial registration of a newly created artwork |
| `E8_Acquisition` | Change of legal custody (sale, donation, bequest) |
| `E11_Modification` | Conservation, restoration, or significant physical change |
| `E7_Activity` | Exhibition loan, temporary transfer |
| `E6_Destruction` | Loss, destruction, or deaccessioning |

Use the same string when calling `anchorBatch(..., eventType)` so the batch’s primary CIDOC class is stored on-chain.

---

## Summary

- **DOMAIN_SEPARATOR:** `keccak256("atsur.provenance.v1")`
- **Leaf:** `keccak256(abi.encodePacked(DOMAIN_SEPARATOR, eventTypeBytes, keccak256(cidocJson)))`
- **Tree:** Sorted leaves; parent = `keccak256(abi.encodePacked(smaller, larger))`
- **Proof:** Sibling path from leaf to root; contract uses sorted comparison at each step.
