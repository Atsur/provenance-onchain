const { expect }        = require("chai");
const { ethers, upgrades } = require("hardhat");

/**
 * AtsurActorRegistry — Hardhat integration tests
 *
 * Covers:
 *   - Initialization
 *   - registerActor (all validation paths)
 *   - linkSelfCustodialWallet (all validation paths)
 *   - updateKycCommitment
 *   - delegateVerifier + certifyVerifierTraining + revokeVerifier
 *   - setActorStatus
 *   - verifyKycCommitment
 *   - isActiveVerifier
 *   - UUPS upgradeability
 *   - Access control (role enforcement on all restricted functions)
 */
describe("AtsurActorRegistry", function () {

    // ─────────────────────────────────────────────
    // HELPERS
    // ─────────────────────────────────────────────

    function makeActorId(uuid) {
        return ethers.keccak256(ethers.toUtf8Bytes(uuid));
    }

    function makeVerifierId(verifierUuid) {
        return ethers.keccak256(ethers.toUtf8Bytes(verifierUuid));
    }

    function makeCommitment(provider, providerUserId, atsurUuid, salt) {
        return ethers.keccak256(
            ethers.solidityPacked(
                ["string", "string", "string", "bytes32"],
                [provider, providerUserId, atsurUuid, salt]
            )
        );
    }

    function makeLinkCommitment(actorId, custodialWallet, newWallet, nonce) {
        return ethers.keccak256(
            ethers.solidityPacked(
                ["bytes32", "address", "address", "bytes32"],
                [actorId, custodialWallet, newWallet, nonce]
            )
        );
    }

    const ActorType   = { E21_Person: 0, E74_Group: 1, E40_LegalBody: 2 };
    const ActorStatus = { Active: 0, Suspended: 1, Revoked: 2 };

    // ─────────────────────────────────────────────
    // FIXTURES
    // ─────────────────────────────────────────────

    let registry;
    let admin, operator, institution, user, stranger;

    const ACTOR_UUID      = "actor-uuid-001";
    const INSTITUTION_UUID = "nga-uuid-001";
    const VERIFIER_UUID   = "verifier-uuid-001";
    const SALT            = ethers.keccak256(ethers.toUtf8Bytes("test-salt"));

    beforeEach(async function () {
        [admin, operator, institution, user, stranger] = await ethers.getSigners();

        const Factory = await ethers.getContractFactory("AtsurActorRegistry");
        registry = await upgrades.deployProxy(
            Factory,
            [admin.address, operator.address],
            { initializer: "initialize", kind: "uups" }
        );
        await registry.waitForDeployment();
    });

    // ─────────────────────────────────────────────
    // INITIALIZATION
    // ─────────────────────────────────────────────

    describe("Initialization", function () {
        it("grants DEFAULT_ADMIN_ROLE to admin", async function () {
            expect(await registry.hasRole(await registry.DEFAULT_ADMIN_ROLE(), admin.address)).to.be.true;
        });

        it("grants OPERATOR_ROLE to operator", async function () {
            expect(await registry.hasRole(await registry.OPERATOR_ROLE(), operator.address)).to.be.true;
        });

        it("reverts with zero admin", async function () {
            const Factory = await ethers.getContractFactory("AtsurActorRegistry");
            await expect(
                upgrades.deployProxy(Factory, [ethers.ZeroAddress, operator.address], { kind: "uups" })
            ).to.be.revertedWithCustomError(registry, "ZeroAddress");
        });

        it("reverts with zero operator", async function () {
            const Factory = await ethers.getContractFactory("AtsurActorRegistry");
            await expect(
                upgrades.deployProxy(Factory, [admin.address, ethers.ZeroAddress], { kind: "uups" })
            ).to.be.revertedWithCustomError(registry, "ZeroAddress");
        });
    });

    // ─────────────────────────────────────────────
    // registerActor
    // ─────────────────────────────────────────────

    describe("registerActor", function () {
        let actorId, commitment;

        beforeEach(function () {
            actorId    = makeActorId(ACTOR_UUID);
            commitment = makeCommitment("smile_id", "smileid-001", ACTOR_UUID, SALT);
        });

        it("registers a new actor and emits ActorRegistered", async function () {
            await expect(
                registry.connect(operator).registerActor(
                    actorId, ActorType.E21_Person, commitment, "smile_id", user.address
                )
            )
                .to.emit(registry, "ActorRegistered")
                .withArgs(actorId, ActorType.E21_Person, 0 /* KYC_Verified */, "smile_id", user.address, anyValue);

            expect(await registry.isActorRegistered(actorId)).to.be.true;
            const actor = await registry.getActor(actorId);
            expect(actor.actorType).to.equal(ActorType.E21_Person);
            expect(actor.custodialWallet).to.equal(user.address);
            expect(actor.kycProvider).to.equal("smile_id");
        });

        it("maps wallet to actorId", async function () {
            await registry.connect(operator).registerActor(
                actorId, ActorType.E21_Person, commitment, "smile_id", user.address
            );
            expect(await registry.walletToActor(user.address)).to.equal(actorId);
        });

        it("allows admin to register (DEFAULT_ADMIN_ROLE can act as operator)", async function () {
            await expect(
                registry.connect(admin).registerActor(
                    actorId, ActorType.E74_Group, commitment, "smile_id", user.address
                )
            ).to.not.be.reverted;
        });

        it("reverts for stranger (no role)", async function () {
            await expect(
                registry.connect(stranger).registerActor(
                    actorId, ActorType.E21_Person, commitment, "smile_id", user.address
                )
            ).to.be.revertedWithCustomError(registry, "NotAtsur");
        });

        it("reverts if actor already registered", async function () {
            await registry.connect(operator).registerActor(
                actorId, ActorType.E21_Person, commitment, "smile_id", user.address
            );
            await expect(
                registry.connect(operator).registerActor(
                    actorId, ActorType.E21_Person, commitment, "smile_id", stranger.address
                )
            ).to.be.revertedWithCustomError(registry, "ActorAlreadyRegistered");
        });

        it("reverts with zero wallet", async function () {
            await expect(
                registry.connect(operator).registerActor(
                    actorId, ActorType.E21_Person, commitment, "smile_id", ethers.ZeroAddress
                )
            ).to.be.revertedWithCustomError(registry, "InvalidWallet");
        });

        it("reverts if wallet already mapped", async function () {
            await registry.connect(operator).registerActor(
                actorId, ActorType.E21_Person, commitment, "smile_id", user.address
            );
            const actorId2 = makeActorId("another-uuid");
            await expect(
                registry.connect(operator).registerActor(
                    actorId2, ActorType.E21_Person, commitment, "smile_id", user.address
                )
            ).to.be.revertedWithCustomError(registry, "WalletAlreadyMapped");
        });

        it("reverts with empty provider string", async function () {
            await expect(
                registry.connect(operator).registerActor(
                    actorId, ActorType.E21_Person, commitment, "", user.address
                )
            ).to.be.revertedWithCustomError(registry, "InvalidKycProvider");
        });

        // SEV-004 fix
        it("reverts InvalidActorId for bytes32(0) actorId", async function () {
            await expect(
                registry.connect(operator).registerActor(
                    ethers.ZeroHash, ActorType.E21_Person, commitment, "smile_id", user.address
                )
            ).to.be.revertedWithCustomError(registry, "InvalidActorId");
        });
    });

    // ─────────────────────────────────────────────
    // linkSelfCustodialWallet
    // ─────────────────────────────────────────────

    describe("linkSelfCustodialWallet", function () {
        let actorId;

        beforeEach(async function () {
            actorId = makeActorId(ACTOR_UUID);
            const commitment = makeCommitment("smile_id", "smileid-001", ACTOR_UUID, SALT);
            await registry.connect(operator).registerActor(
                actorId, ActorType.E21_Person, commitment, "smile_id", user.address
            );
        });

        it("links a self-custodial wallet and emits WalletLinked", async function () {
            const nonce          = ethers.keccak256(ethers.toUtf8Bytes("nonce-1"));
            const linkCommitment = makeLinkCommitment(actorId, user.address, stranger.address, nonce);

            await expect(
                registry.connect(operator).linkSelfCustodialWallet(
                    actorId, stranger.address, nonce, linkCommitment
                )
            )
                .to.emit(registry, "WalletLinked")
                .withArgs(actorId, user.address, stranger.address, linkCommitment, anyValue);

            const actor = await registry.getActor(actorId);
            expect(actor.selfCustodialWallet).to.equal(stranger.address);
            expect(await registry.walletToActor(stranger.address)).to.equal(actorId);
        });

        it("reverts with invalid link commitment", async function () {
            const nonce      = ethers.keccak256(ethers.toUtf8Bytes("nonce-1"));
            const badCommitment = ethers.keccak256(ethers.toUtf8Bytes("wrong"));

            await expect(
                registry.connect(operator).linkSelfCustodialWallet(
                    actorId, stranger.address, nonce, badCommitment
                )
            ).to.be.revertedWithCustomError(registry, "InvalidLinkCommitment");
        });

        it("reverts if wallet already linked", async function () {
            const nonce          = ethers.keccak256(ethers.toUtf8Bytes("nonce-1"));
            const linkCommitment = makeLinkCommitment(actorId, user.address, stranger.address, nonce);
            await registry.connect(operator).linkSelfCustodialWallet(
                actorId, stranger.address, nonce, linkCommitment
            );

            const nonce2          = ethers.keccak256(ethers.toUtf8Bytes("nonce-2"));
            const linkCommitment2 = makeLinkCommitment(actorId, user.address, institution.address, nonce2);
            await expect(
                registry.connect(operator).linkSelfCustodialWallet(
                    actorId, institution.address, nonce2, linkCommitment2
                )
            ).to.be.revertedWithCustomError(registry, "WalletAlreadyLinked");
        });

        it("reverts with zero new wallet", async function () {
            const nonce          = ethers.keccak256(ethers.toUtf8Bytes("nonce-1"));
            const linkCommitment = makeLinkCommitment(actorId, user.address, ethers.ZeroAddress, nonce);
            await expect(
                registry.connect(operator).linkSelfCustodialWallet(
                    actorId, ethers.ZeroAddress, nonce, linkCommitment
                )
            ).to.be.revertedWithCustomError(registry, "InvalidWallet");
        });

        it("reverts if actor does not exist", async function () {
            const fakeId         = makeActorId("fake-uuid");
            const nonce          = ethers.keccak256(ethers.toUtf8Bytes("n"));
            const linkCommitment = makeLinkCommitment(fakeId, user.address, stranger.address, nonce);
            await expect(
                registry.connect(operator).linkSelfCustodialWallet(fakeId, stranger.address, nonce, linkCommitment)
            ).to.be.revertedWithCustomError(registry, "ActorNotActive");
        });
    });

    // ─────────────────────────────────────────────
    // updateKycCommitment
    // ─────────────────────────────────────────────

    describe("updateKycCommitment", function () {
        let actorId;

        beforeEach(async function () {
            actorId = makeActorId(ACTOR_UUID);
            const commitment = makeCommitment("smile_id", "smileid-001", ACTOR_UUID, SALT);
            await registry.connect(operator).registerActor(
                actorId, ActorType.E21_Person, commitment, "smile_id", user.address
            );
        });

        it("updates commitment and provider, emits KycCommitmentUpdated", async function () {
            const newCommitment = makeCommitment("stub", "stub-001", ACTOR_UUID, SALT);
            await expect(
                registry.connect(operator).updateKycCommitment(actorId, newCommitment, "stub")
            )
                .to.emit(registry, "KycCommitmentUpdated")
                .withArgs(actorId, "stub", newCommitment, anyValue);

            const actor = await registry.getActor(actorId);
            expect(actor.kycProvider).to.equal("stub");
            expect(actor.kycCommitment).to.equal(newCommitment);
        });

        it("reverts for non-existent actor", async function () {
            await expect(
                registry.connect(operator).updateKycCommitment(makeActorId("none"), SALT, "smile_id")
            ).to.be.revertedWithCustomError(registry, "ActorNotFound");
        });

        it("reverts with empty provider", async function () {
            await expect(
                registry.connect(operator).updateKycCommitment(actorId, SALT, "")
            ).to.be.revertedWithCustomError(registry, "InvalidKycProvider");
        });
    });

    // ─────────────────────────────────────────────
    // verifyKycCommitment
    // ─────────────────────────────────────────────

    describe("verifyKycCommitment", function () {
        let actorId;
        const providerUserId = "smileid-user-abc";
        const uuid           = ACTOR_UUID;

        beforeEach(async function () {
            actorId = makeActorId(uuid);
            const commitment = makeCommitment("smile_id", providerUserId, uuid, SALT);
            await registry.connect(operator).registerActor(
                actorId, ActorType.E21_Person, commitment, "smile_id", user.address
            );
        });

        // SEV-001: tests now pass the pre-computed commitment hash — salt stays off-chain
        it("returns true for correct commitment", async function () {
            const commitment = makeCommitment("smile_id", providerUserId, uuid, SALT);
            const result     = await registry.verifyKycCommitment(actorId, commitment);
            expect(result).to.be.true;
        });

        it("returns false for wrong salt (wrong commitment)", async function () {
            const wrongSalt  = ethers.keccak256(ethers.toUtf8Bytes("wrong-salt"));
            const commitment = makeCommitment("smile_id", providerUserId, uuid, wrongSalt);
            const result     = await registry.verifyKycCommitment(actorId, commitment);
            expect(result).to.be.false;
        });

        it("returns false for wrong provider user ID (wrong commitment)", async function () {
            const commitment = makeCommitment("smile_id", "wrong-user-id", uuid, SALT);
            const result     = await registry.verifyKycCommitment(actorId, commitment);
            expect(result).to.be.false;
        });

        it("returns false if actor is suspended", async function () {
            await registry.connect(operator).setActorStatus(actorId, ActorStatus.Suspended);
            const commitment = makeCommitment("smile_id", providerUserId, uuid, SALT);
            const result     = await registry.verifyKycCommitment(actorId, commitment);
            expect(result).to.be.false;
        });

        it("reverts ActorNotFound for non-existent actorId", async function () {
            const unknownId  = ethers.keccak256(ethers.toUtf8Bytes("nobody-uuid"));
            const commitment = makeCommitment("smile_id", "uid", "nobody-uuid", SALT);
            await expect(
                registry.verifyKycCommitment(unknownId, commitment)
            ).to.be.revertedWithCustomError(registry, "ActorNotFound");
        });
    });

    // ─────────────────────────────────────────────
    // delegateVerifier + certifyVerifierTraining + revokeVerifier
    // ─────────────────────────────────────────────

    describe("Verifier delegation", function () {
        let institutionActorId, verifierId;

        beforeEach(async function () {
            // Register institution (NGA — E40_LegalBody)
            institutionActorId = makeActorId(INSTITUTION_UUID);
            const commitment   = makeCommitment("smile_id", "nga-001", INSTITUTION_UUID, SALT);
            await registry.connect(operator).registerActor(
                institutionActorId, ActorType.E40_LegalBody, commitment, "smile_id", institution.address
            );
            verifierId = makeVerifierId(VERIFIER_UUID);
        });

        it("delegateVerifier: emits VerifierDelegated + VerifierTrainingPending when not certified", async function () {
            await expect(
                registry.connect(operator).delegateVerifier(institutionActorId, verifierId, false, 0)
            )
                .to.emit(registry, "VerifierDelegated")
                .withArgs(institutionActorId, verifierId, false, anyValue)
                .and.to.emit(registry, "VerifierTrainingPending")
                .withArgs(institutionActorId, verifierId, anyValue);
        });

        it("delegateVerifier: no VerifierTrainingPending when already certified", async function () {
            const now = Math.floor(Date.now() / 1000);
            const tx  = await registry.connect(operator).delegateVerifier(
                institutionActorId, verifierId, true, now
            );
            const receipt = await tx.wait();
            const pendingEvent = receipt.logs.find(
                l => l.fragment?.name === "VerifierTrainingPending"
            );
            expect(pendingEvent).to.be.undefined;
        });

        it("isActiveVerifier: false before certification", async function () {
            await registry.connect(operator).delegateVerifier(institutionActorId, verifierId, false, 0);
            expect(await registry.isActiveVerifier(institutionActorId, verifierId)).to.be.false;
        });

        it("certifyVerifierTraining: activates verifier and emits VerifierTrainingCertified", async function () {
            await registry.connect(operator).delegateVerifier(institutionActorId, verifierId, false, 0);
            await expect(
                registry.connect(operator).certifyVerifierTraining(institutionActorId, verifierId)
            )
                .to.emit(registry, "VerifierTrainingCertified")
                .withArgs(verifierId, institutionActorId, anyValue);

            expect(await registry.isActiveVerifier(institutionActorId, verifierId)).to.be.true;
        });

        it("certifyVerifierTraining: reverts if already certified", async function () {
            await registry.connect(operator).delegateVerifier(institutionActorId, verifierId, false, 0);
            await registry.connect(operator).certifyVerifierTraining(institutionActorId, verifierId);
            await expect(
                registry.connect(operator).certifyVerifierTraining(institutionActorId, verifierId)
            ).to.be.revertedWithCustomError(registry, "VerifierAlreadyCertified");
        });

        it("revokeVerifier: deactivates and emits VerifierRevoked", async function () {
            await registry.connect(operator).delegateVerifier(institutionActorId, verifierId, false, 0);
            await registry.connect(operator).certifyVerifierTraining(institutionActorId, verifierId);
            expect(await registry.isActiveVerifier(institutionActorId, verifierId)).to.be.true;

            await expect(
                registry.connect(operator).revokeVerifier(institutionActorId, verifierId)
            )
                .to.emit(registry, "VerifierRevoked")
                .withArgs(institutionActorId, verifierId, operator.address, anyValue);

            expect(await registry.isActiveVerifier(institutionActorId, verifierId)).to.be.false;
        });

        it("revokeVerifier: reverts if already inactive", async function () {
            await registry.connect(operator).delegateVerifier(institutionActorId, verifierId, false, 0);
            await registry.connect(operator).revokeVerifier(institutionActorId, verifierId);
            await expect(
                registry.connect(operator).revokeVerifier(institutionActorId, verifierId)
            ).to.be.revertedWithCustomError(registry, "VerifierNotActive");
        });

        it("delegateVerifier: reverts for E21_Person institution", async function () {
            const personId   = makeActorId("person-uuid");
            const commitment = makeCommitment("smile_id", "p-001", "person-uuid", SALT);
            await registry.connect(operator).registerActor(
                personId, ActorType.E21_Person, commitment, "smile_id", stranger.address
            );
            await expect(
                registry.connect(operator).delegateVerifier(personId, verifierId, false, 0)
            ).to.be.revertedWithCustomError(registry, "OnlyGroupsOrLegalBodiesCanDelegate");
        });

        it("delegateVerifier: reverts if verifier already active in this institution", async function () {
            await registry.connect(operator).delegateVerifier(institutionActorId, verifierId, false, 0);
            await expect(
                registry.connect(operator).delegateVerifier(institutionActorId, verifierId, false, 0)
            ).to.be.revertedWithCustomError(registry, "VerifierAlreadyActive");
        });

        it("institution wallet can delegate and revoke their own verifiers", async function () {
            await registry.connect(operator).delegateVerifier(institutionActorId, verifierId, false, 0);
            // institution wallet (mapped to institutionActorId) can revoke
            await expect(
                registry.connect(institution).revokeVerifier(institutionActorId, verifierId)
            ).to.not.be.reverted;
        });

        // M-10 (SEV-004)
        it("delegateVerifier: reverts InvalidActorId for bytes32(0) verifierId", async function () {
            await expect(
                registry.connect(operator).delegateVerifier(institutionActorId, ethers.ZeroHash, false, 0)
            ).to.be.revertedWithCustomError(registry, "InvalidActorId");
        });

        // M-17 (SEV-005)
        it("delegateVerifier: reverts VerifierPermanentlyRevoked after revocation", async function () {
            const root2 = makeVerifierId("verifier-uuid-2");

            // Delegate and revoke
            await registry.connect(operator).delegateVerifier(institutionActorId, verifierId, false, 0);
            await registry.connect(operator).revokeVerifier(institutionActorId, verifierId);
            expect(await registry.revokedVerifiers(verifierId)).to.be.true;

            // Attempt to re-delegate the permanently revoked verifierId
            await expect(
                registry.connect(operator).delegateVerifier(institutionActorId, verifierId, false, 0)
            ).to.be.revertedWithCustomError(registry, "VerifierPermanentlyRevoked");

            // Admin can clear the revocation flag
            await registry.connect(admin).clearVerifierRevocation(verifierId);
            expect(await registry.revokedVerifiers(verifierId)).to.be.false;

            // Re-delegation now succeeds
            await expect(
                registry.connect(operator).delegateVerifier(institutionActorId, verifierId, false, 0)
            ).to.not.be.reverted;
        });
    });

    // ─────────────────────────────────────────────
    // setActorStatus
    // ─────────────────────────────────────────────

    describe("setActorStatus", function () {
        let actorId;

        beforeEach(async function () {
            actorId = makeActorId(ACTOR_UUID);
            const commitment = makeCommitment("smile_id", "smileid-001", ACTOR_UUID, SALT);
            await registry.connect(operator).registerActor(
                actorId, ActorType.E21_Person, commitment, "smile_id", user.address
            );
        });

        it("suspends an actor and emits ActorStatusChanged", async function () {
            await expect(registry.connect(operator).setActorStatus(actorId, ActorStatus.Suspended))
                .to.emit(registry, "ActorStatusChanged")
                .withArgs(actorId, ActorStatus.Suspended, operator.address, anyValue);

            const actor = await registry.getActor(actorId);
            expect(actor.status).to.equal(ActorStatus.Suspended);
        });

        it("revokes and reinstates an actor", async function () {
            await registry.connect(operator).setActorStatus(actorId, ActorStatus.Revoked);
            expect((await registry.getActor(actorId)).status).to.equal(ActorStatus.Revoked);

            await registry.connect(operator).setActorStatus(actorId, ActorStatus.Active);
            expect((await registry.getActor(actorId)).status).to.equal(ActorStatus.Active);
        });

        it("reverts for stranger", async function () {
            await expect(
                registry.connect(stranger).setActorStatus(actorId, ActorStatus.Suspended)
            ).to.be.revertedWithCustomError(registry, "NotAtsur");
        });
    });

    // ─────────────────────────────────────────────
    // getActorByWallet
    // ─────────────────────────────────────────────

    describe("getActorByWallet", function () {
        it("returns actor by custodial wallet", async function () {
            const actorId    = makeActorId(ACTOR_UUID);
            const commitment = makeCommitment("smile_id", "s-001", ACTOR_UUID, SALT);
            await registry.connect(operator).registerActor(
                actorId, ActorType.E21_Person, commitment, "smile_id", user.address
            );
            const actor = await registry.getActorByWallet(user.address);
            expect(actor.custodialWallet).to.equal(user.address);
        });

        it("reverts WalletNotMapped for unmapped wallet", async function () {
            await expect(
                registry.getActorByWallet(stranger.address)
            ).to.be.revertedWithCustomError(registry, "WalletNotMapped")
             .withArgs(stranger.address);
        });
    });

    // ─────────────────────────────────────────────
    // UUPS Upgradeability
    // ─────────────────────────────────────────────

    describe("Upgradeability (UUPS)", function () {
        it("admin can upgrade to a new implementation", async function () {
            const Factory = await ethers.getContractFactory("AtsurActorRegistry");
            // Should not revert
            await expect(upgrades.upgradeProxy(await registry.getAddress(), Factory)).to.not.be.reverted;
        });

        it("non-admin cannot upgrade", async function () {
            const Factory = await ethers.getContractFactory("AtsurActorRegistry", stranger);
            await expect(
                upgrades.upgradeProxy(await registry.getAddress(), Factory)
            ).to.be.reverted;
        });

        // L-6 (SEV-009)
        it("reverts NotAContract when upgrading to an EOA address", async function () {
            const eoaAddress = stranger.address;
            await expect(
                registry.connect(admin).upgradeToAndCall(eoaAddress, "0x")
            ).to.be.revertedWithCustomError(registry, "NotAContract");
        });
    });
});

// ─── Chai helper for anyValue ────────────────
function anyValue() { return true; }
