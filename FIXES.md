# Atsur Audit Fixes — Progress Tracker

Legend: [ ] = pending · [x] = done · [DEFERRED] = intentionally skipped

## HIGH

### SEV-002 — anchorBatch: add batchId existence guard (AtsurProvenance.sol)
- [x] H-1: Declare `error BatchAlreadyExists(bytes32 batchId)` in the errors section
- [x] H-2: After line 302 (batchId assignment), add:
         `if (batches[batchId].exists) revert BatchAlreadyExists(batchId);`
- [x] H-3: Add Hardhat test: same nonce in same block → second call reverts
           BatchAlreadyExists
- [x] H-4: Add Foundry test: equivalent coverage
- [x] H-5: Run npx hardhat test + forge test — all pass (87 HH + 63 Foundry)

### SEV-001 — verifyKycCommitment: remove salt from public API (AtsurActorRegistry.sol)
- [x] H-6: Changed to `verifyKycCommitment(bytes32 actorId, bytes32 claimedCommitment)`; kept actorMustExist (user choice)
- [x] H-7: BREAKING CHANGE comment added above function
- [x] H-8: Updated all 5-arg test call sites in HH + Foundry to 2-arg form
- [x] H-9: Added ActorNotFound revert test in HH + Foundry; updated 4 existing tests
- [x] H-10: Run npx hardhat test + forge test — all pass (88 HH + 64 Foundry)

## MEDIUM

### SEV-003 — anchorBatch: reject zero Merkle root (AtsurProvenance.sol)
- [x] M-1: Declared `error InvalidMerkleRoot(bytes32 root)` in errors section
- [x] M-2: Added `if (merkleRoot == bytes32(0)) revert InvalidMerkleRoot(merkleRoot);` before usedMerkleRoots check
- [x] M-3: Added Hardhat test: anchorBatch(ZeroHash, ...) reverts InvalidMerkleRoot
- [x] M-4: Added Foundry test: equivalent
- [x] M-5: Run npx hardhat test + forge test — all pass (89 HH + 65 Foundry)

### SEV-004 — registerActor: reject bytes32(0) actorId (AtsurActorRegistry.sol)
- [x] M-6: Declare `error InvalidActorId()` in the errors section
- [x] M-7: Add guard at the top of registerActor (before actorExists check):
         `if (actorId == bytes32(0)) revert InvalidActorId();`
- [x] M-8: Also add the same guard to delegateVerifier for verifierId:
         `if (verifierId == bytes32(0)) revert InvalidActorId();`
         (Ask the user if a more specific error name like InvalidVerifierId is preferred.)
- [x] M-9: Add Hardhat test: registerActor(bytes32(0), ...) reverts InvalidActorId
- [x] M-10: Add Hardhat test: delegateVerifier(..., bytes32(0), ...) reverts
- [x] M-11: Run npx hardhat test + forge test — all pass

### SEV-005 — revokeVerifier: prevent re-delegation after revocation (AtsurActorRegistry.sol)
- [x] M-12: Add storage variable: `mapping(bytes32 => bool) public revokedVerifiers;`
            Place it immediately after the `verifierToInstitution` mapping
            (before __gap to preserve gap sizing — reduce __gap from [50] to [49])
- [x] M-13: Declare `error VerifierPermanentlyRevoked(bytes32 verifierId)` in errors
- [x] M-14: In revokeVerifier(), after setting d.active = false, add:
          `revokedVerifiers[verifierId] = true;`
- [x] M-15: In delegateVerifier(), after the VerifierAlreadyDelegatedElsewhere check, add:
          `if (revokedVerifiers[verifierId]) revert VerifierPermanentlyRevoked(verifierId);`
- [x] M-16: Ask user: should Atsur (admin) be able to override the permanent revocation
            and re-delegate a verifier despite the flag? If yes, add an admin-only
            `clearVerifierRevocation(bytes32 verifierId)` function. Do not implement
            without a clear answer.
- [x] M-17: Add Hardhat test: delegate → revoke → attempt re-delegate → reverts
            VerifierPermanentlyRevoked
- [x] M-18: Run npx hardhat test + forge test — all pass (92 HH + 67 Foundry)

### SEV-006 — anchorBatch: check submitterActorId is active, not just exists (AtsurProvenance.sol)
- [x] M-19: Replace the actorExists check in anchorBatch with getActor() + status check
- [x] M-20: Declare `error SubmitterNotActive(bytes32 submitterActorId)` in errors
- [x] M-21: Add Hardhat test: suspend a registered actor in the registry, then attempt
            to anchor a batch with that actorId as submitter → reverts SubmitterNotActive
- [x] M-22: Run npx hardhat test + forge test — all pass (93 HH + 68 Foundry)

### SEV-007 — linkSelfCustodialWallet: document trust assumption (AtsurActorRegistry.sol)
- [DEFERRED] Add NatSpec @dev warning to linkSelfCustodialWallet:
  "@dev TRUST ASSUMPTION: the operator (onlyAtsur) fully controls the nonce and
   therefore can compute a valid linkCommitment for any newWallet without proof of
   that wallet's consent. ECDSA signature verification from newWallet is deferred
   to a future upgrade. Do not expose this function to untrusted operators."
  Mark as DEFERRED in this file — no code change needed beyond NatSpec.

## LOW

### SEV-008 — unpauseBatchCommits: require admin role (AtsurProvenance.sol)
- [x] L-1: Change `function unpauseBatchCommits() external onlyRole(PAUSER_ROLE)`
           to `onlyRole(DEFAULT_ADMIN_ROLE)`
- [x] L-2: Add Hardhat test: PAUSER_ROLE holder can pause but cannot unpause;
           DEFAULT_ADMIN_ROLE holder can unpause
- [x] L-3: Run npx hardhat test + forge test — all pass (94 HH + 69 Foundry)

### SEV-009 — _authorizeUpgrade: validate newImplementation is a contract (both contracts)
- [x] L-4: In AtsurActorRegistry.sol, change _authorizeUpgrade to check code.length;
           Declared `error NotAContract(address addr)` in errors section.
- [x] L-5: Applied the same change to AtsurProvenance.sol
- [x] L-6: Added Hardhat + Foundry test for each contract: upgrading to an EOA reverts NotAContract
- [x] L-7: Run npx hardhat test + forge test — all pass (96 HH + 71 Foundry)

### SEV-012 — Replace custom nonReentrant with OZ ReentrancyGuardUpgradeable (AtsurProvenance.sol)
- [x] L-8: Added `ReentrancyGuardUpgradeable` import (copied file from npm v5.4.0 into
           Foundry lib — submodule v5.5.0 was missing it)
- [x] L-9: Added to inheritance chain
- [x] L-10: Added `__ReentrancyGuard_init()` to initialize()
- [x] L-11: Removed `_NOT_ENTERED`, `_ENTERED`, `_status`, and custom `nonReentrant` modifier
- [x] L-12: OZ modifier name `nonReentrant` matches — all usages unchanged
- [x] L-13: __gap increased from [50] to [51] to compensate for removed `_status` slot;
            OZ v5.4 ReentrancyGuardUpgradeable uses ERC-7201 namespaced storage (0 sequential slots)
- [x] L-14: Run npx hardhat test + forge test — all pass (96 HH + 71 Foundry)

## GAS

### SEV-013 — Remove redundant zero check in _validateArweaveTxId (AtsurProvenance.sol)
- [x] G-1: Removed first line of _validateArweaveTxId(); left explanatory comment why
- [x] G-2: Run npx hardhat test + forge test — all pass (96 HH + 71 Foundry)

### SEV-017 — verifyProof / verifyProofView: calldata for proof arrays (AtsurProvenance.sol)
- [x] G-3: Changed `bytes32[] memory proof` to `bytes32[] calldata proof` in both functions
- [x] G-4: Changed to `MerkleProof.verifyCalldata(proof, ...)` in both functions
- [x] G-5: Run npx hardhat test + forge test — all pass

### SEV-020 — verifyProof: only emit ProofVerified when valid (AtsurProvenance.sol)
- [x] G-6: Wrapped emit: `if (isValid) emit ProofVerified(batchId, leafHash, isValid);`
- [x] G-7: Run npx hardhat test + forge test — all pass (96 HH + 71 Foundry)

### SEV-014 + SEV-015 — Remove redundant actorId field and actorExists mapping
- [x] G-8: Confirmed clean testnet — no live data, no migration needed
- [x] G-9: Removed `bytes32 actorId` from Actor struct (slot 0 freed → struct is 1 slot smaller)
- [x] G-10: Removed `mapping(bytes32 => bool) public actorExists` from storage
- [x] G-11: Replaced all `actorExists[id]` reads with `actors[id].registeredAt != 0`
- [x] G-12: Updated actorMustExist and actorMustBeActive modifiers
- [x] G-13: Added isActorRegistered() view; AtsurProvenance uses it instead of actorExists
- [x] G-14: __gap increased from [49] to [50] (actorExists slot absorbed by gap)
- [x] G-15: Updated all tests (actorExists → isActorRegistered, actor.actorId → custodialWallet)
- [x] G-16: Run npx hardhat test + forge test — all pass (96 HH + 72 Foundry;
            verifyKycCommitment gas dropped ~44k from smaller struct)

### SEV-016 — Add isActorActive view to registry (AtsurActorRegistry.sol)
- [x] G-17: Added `isActorActive(bytes32 actorId)` view: registeredAt != 0 && status == Active
- [x] G-18: Updated _requireActiveActor to call actorRegistry.isActorActive() (one line)
- [x] G-19: Error remains AttestorNotActive — correct
- [x] G-20: Run npx hardhat test + forge test — all pass (96 HH + 72 Foundry)

## INFORMATIONAL

### SEV-021 — getActorByWallet: include wallet in error (AtsurActorRegistry.sol)
- [x] I-1: Declared `error WalletNotMapped(address wallet)` in errors
- [x] I-2: Replaced `revert ActorNotFound(bytes32(0))` with `revert WalletNotMapped(wallet)`
- [x] I-3: Run npx hardhat test + forge test — all pass (96 HH + 72 Foundry)

### SEV-022 — Remove TODO comments / add NatSpec (both contracts)
- [x] I-4: Removed both TODO comments from AtsurActorRegistry.sol
- [x] I-5: Added @dev note referencing registry-cloud's ActorRegistryService.certifyVerifierTraining()
- [x] I-6: Run npx hardhat test + forge test — all pass

### SEV-024 — fromActorId=bytes32(0): add named constant + NatSpec (AtsurProvenance.sol)
- [x] I-7: Added `bytes32 public constant GENESIS_ACTOR = bytes32(0);`
- [x] I-8: Updated @param fromActorId in recordCustodyTransfer to reference GENESIS_ACTOR
- [x] I-9: Run npx hardhat test + forge test — all pass (96 HH + 72 Foundry)

---

## Open Source Hardening (post-audit)

### OSS-1 — Separate upgrade authority with UPGRADER_ROLE (both contracts)
- [x] OSS-1a: Added `bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE")` to AtsurActorRegistry
- [x] OSS-1b: Added same constant to AtsurProvenance
- [x] OSS-1c: Updated `_authorizeUpgrade` on both contracts to `onlyRole(UPGRADER_ROLE)`
- [x] OSS-1d: `initialize()` grants UPGRADER_ROLE to admin (transferred to TimelockController via setupTimelock.js before mainnet)
- [x] OSS-1e: Updated NatSpec on both contracts and initialize() to document the role separation

### OSS-2 — TimelockController deployment support
- [x] OSS-2a: Updated `deployAll.js` — optional `TIMELOCK_DELAY` env var deploys OZ TimelockController,
             grants UPGRADER_ROLE to it, revokes from deployer; if no timelock, UPGRADER_ROLE follows
             multisig transfer
- [x] OSS-2b: Created `scripts/setupTimelock.js` — post-deployment script for existing contracts;
             deploys TimelockController, grants UPGRADER_ROLE, revokes from admin, prints Safe calldata

### OSS-3 — SECURITY.md
- [x] OSS-3a: Created SECURITY.md with responsible disclosure policy (GitHub Security Advisories),
             scope definition, known trust assumptions (admin key, SEV-007, clearVerifierRevocation)

- [x] OSS-4: Run npx hardhat test + forge test — all pass (96 HH + 72 Foundry)

---

## Session Log
<!-- Append a line here each time you resume, with a timestamp and what was last completed -->
- 2026-05-14: Session started. FIXES.md created. Beginning H-1 (SEV-002).
- 2026-05-14: All 24 findings resolved. Final state: 96 HH + 72 Foundry tests passing.
              SEV-007 DEFERRED (NatSpec only, no code change). SEV-014+015 applied
              (clean testnet confirmed). Only remaining item: SEV-016 isActorRegistered
              added as bonus. All [x] complete.
- 2026-06-20: Corrected stale checkboxes for M-6 through M-16 (SEV-004/SEV-005) — the
              corresponding code (InvalidActorId guards, revokedVerifiers mapping,
              VerifierPermanentlyRevoked, clearVerifierRevocation) was already implemented
              and tested; the checklist simply hadn't been updated to reflect it.
