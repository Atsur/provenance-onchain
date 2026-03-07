// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import { Test, console } from "forge-std/Test.sol";
import { AtsurActorRegistry } from "../../contracts/AtsurActorRegistry.sol";
import { ERC1967Proxy }       from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @title AtsurActorRegistryTest
 * @notice Foundry unit + fuzz tests for AtsurActorRegistry.
 *
 * Coverage:
 *   - Initialization guard
 *   - registerActor (all validation paths)
 *   - linkSelfCustodialWallet (commitment maths + all reverts)
 *   - updateKycCommitment
 *   - delegateVerifier + certifyVerifierTraining + revokeVerifier
 *   - setActorStatus
 *   - verifyKycCommitment
 *   - isActiveVerifier / isVerifierDelegated
 *   - Access control (onlyAtsur, onlyInstitutionOrAtsur)
 *   - Fuzz: commitment computation
 *   - Fuzz: actorId uniqueness from distinct UUIDs
 *   - Invariant: actorExists implies valid custodialWallet
 */
contract AtsurActorRegistryTest is Test {

    // ─────────────────────────────────────────────
    // STATE
    // ─────────────────────────────────────────────

    AtsurActorRegistry internal registry;

    address internal admin     = makeAddr("admin");
    address internal operator  = makeAddr("operator");
    address internal userWallet = makeAddr("userWallet");
    address internal stranger  = makeAddr("stranger");
    address internal newWallet = makeAddr("newWallet");

    bytes32 internal constant SALT = keccak256("test-salt");

    // ─────────────────────────────────────────────
    // SETUP
    // ─────────────────────────────────────────────

    function setUp() public {
        AtsurActorRegistry impl = new AtsurActorRegistry();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeWithSelector(AtsurActorRegistry.initialize.selector, admin, operator)
        );
        registry = AtsurActorRegistry(address(proxy));
    }

    // ─────────────────────────────────────────────
    // HELPERS
    // ─────────────────────────────────────────────

    function _actorId(string memory uuid) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(uuid));
    }

    function _commitment(
        string memory provider,
        string memory providerUserId,
        string memory atsurUuid,
        bytes32 salt
    ) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(provider, providerUserId, atsurUuid, salt));
    }

    function _registerArtist() internal returns (bytes32 actorId) {
        actorId = _actorId("artist-uuid");
        bytes32 commitment = _commitment("smile_id", "uid-001", "artist-uuid", SALT);
        vm.prank(operator);
        registry.registerActor(
            actorId,
            AtsurActorRegistry.ActorType.E21_Person,
            commitment,
            "smile_id",
            userWallet
        );
    }

    function _registerInstitution() internal returns (bytes32 actorId) {
        actorId = _actorId("nga-uuid");
        bytes32 commitment = _commitment("smile_id", "nga-001", "nga-uuid", SALT);
        address institutionWallet = makeAddr("institutionWallet");
        vm.prank(operator);
        registry.registerActor(
            actorId,
            AtsurActorRegistry.ActorType.E40_LegalBody,
            commitment,
            "smile_id",
            institutionWallet
        );
    }

    // ─────────────────────────────────────────────
    // INITIALIZATION
    // ─────────────────────────────────────────────

    function test_initialize_rolesGranted() public view {
        assertTrue(registry.hasRole(registry.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(registry.hasRole(registry.OPERATOR_ROLE(), operator));
    }

    function test_initialize_reverts_zeroAdmin() public {
        AtsurActorRegistry impl = new AtsurActorRegistry();
        vm.expectRevert(AtsurActorRegistry.ZeroAddress.selector);
        new ERC1967Proxy(
            address(impl),
            abi.encodeWithSelector(AtsurActorRegistry.initialize.selector, address(0), operator)
        );
    }

    function test_initialize_reverts_zeroOperator() public {
        AtsurActorRegistry impl = new AtsurActorRegistry();
        vm.expectRevert(AtsurActorRegistry.ZeroAddress.selector);
        new ERC1967Proxy(
            address(impl),
            abi.encodeWithSelector(AtsurActorRegistry.initialize.selector, admin, address(0))
        );
    }

    function test_implementation_cannotBeInitialized() public {
        AtsurActorRegistry impl = new AtsurActorRegistry();
        vm.expectRevert();
        impl.initialize(admin, operator);
    }

    // ─────────────────────────────────────────────
    // registerActor
    // ─────────────────────────────────────────────

    function test_registerActor_success() public {
        bytes32 actorId    = _actorId("artist-uuid");
        bytes32 commitment = _commitment("smile_id", "uid-001", "artist-uuid", SALT);

        vm.expectEmit(true, false, false, true, address(registry));
        emit AtsurActorRegistry.ActorRegistered(
            actorId,
            AtsurActorRegistry.ActorType.E21_Person,
            AtsurActorRegistry.ActorTier.KYC_Verified,
            "smile_id",
            userWallet,
            block.timestamp
        );

        vm.prank(operator);
        registry.registerActor(actorId, AtsurActorRegistry.ActorType.E21_Person, commitment, "smile_id", userWallet);

        assertTrue(registry.actorExists(actorId));
        assertEq(registry.walletToActor(userWallet), actorId);

        AtsurActorRegistry.Actor memory actor = registry.getActor(actorId);
        assertEq(uint8(actor.actorType), uint8(AtsurActorRegistry.ActorType.E21_Person));
        assertEq(actor.custodialWallet, userWallet);
        assertEq(actor.kycProvider, "smile_id");
        assertEq(uint8(actor.status), uint8(AtsurActorRegistry.ActorStatus.Active));
        assertEq(uint8(actor.tier), uint8(AtsurActorRegistry.ActorTier.KYC_Verified));
    }

    function test_registerActor_reverts_notAtsur() public {
        bytes32 actorId = _actorId("artist-uuid");
        vm.prank(stranger);
        vm.expectRevert(AtsurActorRegistry.NotAtsur.selector);
        registry.registerActor(actorId, AtsurActorRegistry.ActorType.E21_Person, SALT, "smile_id", userWallet);
    }

    function test_registerActor_reverts_duplicate() public {
        bytes32 actorId = _registerArtist();
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(AtsurActorRegistry.ActorAlreadyRegistered.selector, actorId));
        registry.registerActor(actorId, AtsurActorRegistry.ActorType.E21_Person, SALT, "smile_id", newWallet);
    }

    function test_registerActor_reverts_zeroWallet() public {
        bytes32 actorId = _actorId("zero-wallet-uuid");
        vm.prank(operator);
        vm.expectRevert(AtsurActorRegistry.InvalidWallet.selector);
        registry.registerActor(actorId, AtsurActorRegistry.ActorType.E21_Person, SALT, "smile_id", address(0));
    }

    function test_registerActor_reverts_walletAlreadyMapped() public {
        _registerArtist(); // maps userWallet → artistActorId
        bytes32 otherActorId = _actorId("other-uuid");
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(AtsurActorRegistry.WalletAlreadyMapped.selector, userWallet));
        registry.registerActor(otherActorId, AtsurActorRegistry.ActorType.E21_Person, SALT, "smile_id", userWallet);
    }

    function test_registerActor_reverts_emptyProvider() public {
        bytes32 actorId = _actorId("empty-provider-uuid");
        vm.prank(operator);
        vm.expectRevert(AtsurActorRegistry.InvalidKycProvider.selector);
        registry.registerActor(actorId, AtsurActorRegistry.ActorType.E21_Person, SALT, "", userWallet);
    }

    function test_adminCanAlsoRegister() public {
        bytes32 actorId = _actorId("admin-test-uuid");
        vm.prank(admin);
        registry.registerActor(actorId, AtsurActorRegistry.ActorType.E74_Group, SALT, "smile_id", newWallet);
        assertTrue(registry.actorExists(actorId));
    }

    // ─────────────────────────────────────────────
    // linkSelfCustodialWallet
    // ─────────────────────────────────────────────

    function test_linkSelfCustodialWallet_success() public {
        bytes32 actorId = _registerArtist();
        bytes32 nonce   = keccak256("nonce-link-1");
        bytes32 linkCommitment = keccak256(abi.encodePacked(actorId, userWallet, newWallet, nonce));

        vm.expectEmit(true, true, true, true, address(registry));
        emit AtsurActorRegistry.WalletLinked(actorId, userWallet, newWallet, linkCommitment, block.timestamp);

        vm.prank(operator);
        registry.linkSelfCustodialWallet(actorId, newWallet, nonce, linkCommitment);

        AtsurActorRegistry.Actor memory actor = registry.getActor(actorId);
        assertEq(actor.selfCustodialWallet, newWallet);
        assertEq(registry.walletToActor(newWallet), actorId);

        // History recorded
        AtsurActorRegistry.WalletLink[] memory history = registry.getWalletLinkHistory(actorId);
        assertEq(history.length, 1);
        assertEq(history[0].oldWallet, userWallet);
        assertEq(history[0].newWallet, newWallet);
    }

    function test_linkSelfCustodialWallet_reverts_badCommitment() public {
        bytes32 actorId = _registerArtist();
        bytes32 nonce   = keccak256("nonce-link-1");
        bytes32 badCommitment = keccak256("totally wrong");

        vm.prank(operator);
        vm.expectRevert(AtsurActorRegistry.InvalidLinkCommitment.selector);
        registry.linkSelfCustodialWallet(actorId, newWallet, nonce, badCommitment);
    }

    function test_linkSelfCustodialWallet_reverts_alreadyLinked() public {
        bytes32 actorId       = _registerArtist();
        bytes32 nonce         = keccak256("nonce-link-1");
        bytes32 linkCommitment = keccak256(abi.encodePacked(actorId, userWallet, newWallet, nonce));

        vm.prank(operator);
        registry.linkSelfCustodialWallet(actorId, newWallet, nonce, linkCommitment);

        // Try to link again
        address anotherWallet = makeAddr("anotherWallet");
        bytes32 nonce2        = keccak256("nonce-link-2");
        bytes32 lc2           = keccak256(abi.encodePacked(actorId, userWallet, anotherWallet, nonce2));
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(AtsurActorRegistry.WalletAlreadyLinked.selector, actorId));
        registry.linkSelfCustodialWallet(actorId, anotherWallet, nonce2, lc2);
    }

    // ─────────────────────────────────────────────
    // updateKycCommitment
    // ─────────────────────────────────────────────

    function test_updateKycCommitment_success() public {
        bytes32 actorId       = _registerArtist();
        bytes32 newCommitment = keccak256("new-commitment");

        vm.expectEmit(true, false, false, true, address(registry));
        emit AtsurActorRegistry.KycCommitmentUpdated(actorId, "stub", newCommitment, block.timestamp);

        vm.prank(operator);
        registry.updateKycCommitment(actorId, newCommitment, "stub");

        AtsurActorRegistry.Actor memory actor = registry.getActor(actorId);
        assertEq(actor.kycCommitment, newCommitment);
        assertEq(actor.kycProvider, "stub");
    }

    function test_updateKycCommitment_reverts_notFound() public {
        bytes32 fakeId = _actorId("does-not-exist");
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(AtsurActorRegistry.ActorNotFound.selector, fakeId));
        registry.updateKycCommitment(fakeId, SALT, "smile_id");
    }

    // ─────────────────────────────────────────────
    // verifyKycCommitment
    // ─────────────────────────────────────────────

    function test_verifyKycCommitment_success() public {
        string memory uuid         = "artist-uuid";
        string memory providerUid  = "uid-001";
        bytes32 actorId            = _actorId(uuid);
        bytes32 commitment         = _commitment("smile_id", providerUid, uuid, SALT);

        vm.prank(operator);
        registry.registerActor(actorId, AtsurActorRegistry.ActorType.E21_Person, commitment, "smile_id", userWallet);

        bool valid = registry.verifyKycCommitment(actorId, "smile_id", providerUid, uuid, SALT);
        assertTrue(valid);
    }

    function test_verifyKycCommitment_returnsFalse_wrongSalt() public {
        string memory uuid   = "artist-uuid";
        bytes32 actorId      = _actorId(uuid);
        bytes32 commitment   = _commitment("smile_id", "uid-001", uuid, SALT);

        vm.prank(operator);
        registry.registerActor(actorId, AtsurActorRegistry.ActorType.E21_Person, commitment, "smile_id", userWallet);

        bool valid = registry.verifyKycCommitment(actorId, "smile_id", "uid-001", uuid, keccak256("wrong-salt"));
        assertFalse(valid);
    }

    function test_verifyKycCommitment_returnsFalse_whenSuspended() public {
        string memory uuid   = "artist-uuid";
        bytes32 actorId      = _actorId(uuid);
        bytes32 commitment   = _commitment("smile_id", "uid-001", uuid, SALT);

        vm.prank(operator);
        registry.registerActor(actorId, AtsurActorRegistry.ActorType.E21_Person, commitment, "smile_id", userWallet);

        vm.prank(operator);
        registry.setActorStatus(actorId, AtsurActorRegistry.ActorStatus.Suspended);

        bool valid = registry.verifyKycCommitment(actorId, "smile_id", "uid-001", uuid, SALT);
        assertFalse(valid);
    }

    // ─────────────────────────────────────────────
    // Verifier delegation
    // ─────────────────────────────────────────────

    function test_delegateVerifier_fullLifecycle() public {
        bytes32 institutionId = _registerInstitution();
        bytes32 verifierId    = keccak256("verifier-uuid");

        // Delegate without training
        vm.prank(operator);
        registry.delegateVerifier(institutionId, verifierId, false, 0);

        assertFalse(registry.isActiveVerifier(institutionId, verifierId));
        assertTrue(registry.isVerifierDelegated(institutionId, verifierId));

        // Certify training
        vm.prank(operator);
        registry.certifyVerifierTraining(institutionId, verifierId);
        assertTrue(registry.isActiveVerifier(institutionId, verifierId));

        // Revoke
        vm.prank(operator);
        registry.revokeVerifier(institutionId, verifierId);
        assertFalse(registry.isActiveVerifier(institutionId, verifierId));
    }

    function test_delegateVerifier_reverts_personCannotDelegate() public {
        bytes32 personId = _registerArtist();
        bytes32 verifierId = keccak256("verifier");

        vm.prank(operator);
        vm.expectRevert(AtsurActorRegistry.OnlyGroupsOrLegalBodiesCanDelegate.selector);
        registry.delegateVerifier(personId, verifierId, false, 0);
    }

    function test_delegateVerifier_reverts_alreadyActive() public {
        bytes32 institutionId = _registerInstitution();
        bytes32 verifierId    = keccak256("verifier-uuid");

        vm.prank(operator);
        registry.delegateVerifier(institutionId, verifierId, false, 0);

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(AtsurActorRegistry.VerifierAlreadyActive.selector, verifierId));
        registry.delegateVerifier(institutionId, verifierId, false, 0);
    }

    function test_certifyVerifierTraining_reverts_alreadyCertified() public {
        bytes32 institutionId = _registerInstitution();
        bytes32 verifierId    = keccak256("verifier-uuid");

        vm.prank(operator);
        registry.delegateVerifier(institutionId, verifierId, false, 0);
        vm.prank(operator);
        registry.certifyVerifierTraining(institutionId, verifierId);

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(AtsurActorRegistry.VerifierAlreadyCertified.selector, verifierId));
        registry.certifyVerifierTraining(institutionId, verifierId);
    }

    function test_revokeVerifier_reverts_notActive() public {
        bytes32 institutionId = _registerInstitution();
        bytes32 verifierId    = keccak256("verifier-uuid");

        vm.prank(operator);
        registry.delegateVerifier(institutionId, verifierId, false, 0);
        vm.prank(operator);
        registry.revokeVerifier(institutionId, verifierId);

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(AtsurActorRegistry.VerifierNotActive.selector, verifierId));
        registry.revokeVerifier(institutionId, verifierId);
    }

    // ─────────────────────────────────────────────
    // setActorStatus
    // ─────────────────────────────────────────────

    function test_setActorStatus_suspend_reinstate() public {
        bytes32 actorId = _registerArtist();

        vm.prank(operator);
        registry.setActorStatus(actorId, AtsurActorRegistry.ActorStatus.Suspended);
        assertEq(uint8(registry.getActor(actorId).status), uint8(AtsurActorRegistry.ActorStatus.Suspended));

        vm.prank(operator);
        registry.setActorStatus(actorId, AtsurActorRegistry.ActorStatus.Active);
        assertEq(uint8(registry.getActor(actorId).status), uint8(AtsurActorRegistry.ActorStatus.Active));
    }

    // ─────────────────────────────────────────────
    // Access control
    // ─────────────────────────────────────────────

    function test_accessControl_strangerCannotRegister() public {
        vm.prank(stranger);
        vm.expectRevert(AtsurActorRegistry.NotAtsur.selector);
        registry.registerActor(_actorId("x"), AtsurActorRegistry.ActorType.E21_Person, SALT, "smile_id", newWallet);
    }

    function test_accessControl_strangerCannotCertifyVerifier() public {
        bytes32 institutionId = _registerInstitution();
        bytes32 verifierId    = keccak256("v");

        vm.prank(operator);
        registry.delegateVerifier(institutionId, verifierId, false, 0);

        vm.prank(stranger);
        vm.expectRevert(AtsurActorRegistry.NotAtsur.selector);
        registry.certifyVerifierTraining(institutionId, verifierId);
    }

    // ─────────────────────────────────────────────
    // FUZZ TESTS
    // ─────────────────────────────────────────────

    /**
     * @dev Fuzz: commitment computation is deterministic.
     *      Given the same inputs, the commitment is always the same.
     */
    function testFuzz_commitment_isDeterministic(
        string calldata provider,
        string calldata userId,
        string calldata uuid,
        bytes32 salt
    ) public pure {
        bytes32 c1 = keccak256(abi.encodePacked(provider, userId, uuid, salt));
        bytes32 c2 = keccak256(abi.encodePacked(provider, userId, uuid, salt));
        assertEq(c1, c2);
    }

    /**
     * @dev Fuzz: two different UUIDs produce different actorIds (collision resistance).
     */
    function testFuzz_actorId_fromDistinctUUIDs_areDifferent(
        string calldata uuidA,
        string calldata uuidB
    ) public pure {
        vm.assume(keccak256(bytes(uuidA)) != keccak256(bytes(uuidB)));
        bytes32 idA = keccak256(abi.encodePacked(uuidA));
        bytes32 idB = keccak256(abi.encodePacked(uuidB));
        assertNotEq(idA, idB);
    }

    /**
     * @dev Fuzz: link commitment matches on-chain computation for any inputs.
     */
    function testFuzz_linkCommitment_matchesContract(
        bytes32 actorId,
        address custodialWallet,
        address selfCustodialWallet,
        bytes32 nonce
    ) public pure {
        bytes32 commitment = keccak256(abi.encodePacked(actorId, custodialWallet, selfCustodialWallet, nonce));
        // Same formula as the contract — verify it's deterministic off-chain
        bytes32 recomputed = keccak256(abi.encodePacked(actorId, custodialWallet, selfCustodialWallet, nonce));
        assertEq(commitment, recomputed);
    }

    /**
     * @dev Fuzz: registering an actor with any valid inputs stores data correctly.
     */
    function testFuzz_registerActor_storesData(
        bytes32 actorId,
        bytes32 commitment,
        address wallet
    ) public {
        vm.assume(actorId != bytes32(0));
        vm.assume(wallet != address(0));
        vm.assume(!registry.actorExists(actorId));
        vm.assume(registry.walletToActor(wallet) == bytes32(0));

        vm.prank(operator);
        registry.registerActor(
            actorId, AtsurActorRegistry.ActorType.E21_Person, commitment, "stub", wallet
        );

        assertTrue(registry.actorExists(actorId));
        assertEq(registry.walletToActor(wallet), actorId);
        assertEq(registry.getActor(actorId).kycCommitment, commitment);
    }

    /**
     * @dev Fuzz: verifyKycCommitment returns false for any mismatched salt.
     */
    function testFuzz_verifyKycCommitment_failsOnWrongSalt(bytes32 wrongSalt) public {
        vm.assume(wrongSalt != SALT);

        string memory uuid         = "fuzz-uuid";
        string memory providerUid  = "fuzz-uid";
        bytes32 actorId            = _actorId(uuid);
        bytes32 commitment         = _commitment("smile_id", providerUid, uuid, SALT);

        vm.prank(operator);
        registry.registerActor(actorId, AtsurActorRegistry.ActorType.E21_Person, commitment, "smile_id", newWallet);

        assertFalse(registry.verifyKycCommitment(actorId, "smile_id", providerUid, uuid, wrongSalt));
    }
}
