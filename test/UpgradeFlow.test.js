const { expect }           = require("chai");
const { ethers, upgrades } = require("hardhat");
const { time }              = require("@nomicfoundation/hardhat-network-helpers");

/**
 * UpgradeFlow — end-to-end test of the production upgrade path.
 *
 * Verifies the governance fix described in SECURITY.md: UPGRADER_ROLE is self-administered
 * (_setRoleAdmin(UPGRADER_ROLE, UPGRADER_ROLE) in initialize()), so once it is transferred to a
 * TimelockController, the Gnosis Safe (DEFAULT_ADMIN_ROLE holder) cannot re-grant itself upgrade
 * authority and cannot upgrade directly — every upgrade must go through
 * schedule() -> wait the delay -> execute() on the timelock.
 *
 * Also verifies storage continuity: existing proxy data survives a real UUPS upgrade to a new
 * implementation (MockProvenanceV2 / MockRegistryV2) that appends one new storage field.
 */
describe("Upgrade flow (TimelockController + self-administered UPGRADER_ROLE)", function () {
    const TIMELOCK_DELAY = 60; // seconds — short delay for testing
    const SALT            = ethers.keccak256(ethers.toUtf8Bytes("upgrade-flow-test-salt"));
    const PREDECESSOR     = ethers.ZeroHash;

    async function deployTimelock(adminAddress) {
        const TimelockFactory = await ethers.getContractFactory("TimelockController");
        const timelock = await TimelockFactory.deploy(
            TIMELOCK_DELAY,
            [adminAddress],
            [adminAddress],
            ethers.ZeroAddress // self-administration disabled
        );
        await timelock.waitForDeployment();
        return timelock;
    }

    // ─────────────────────────────────────────────────────────────────────
    // AtsurProvenance
    // ─────────────────────────────────────────────────────────────────────
    describe("AtsurProvenance", function () {
        let registry, provenance, timelock;
        let deployer, safe, operator, stranger;
        let UPGRADER_ROLE, DEFAULT_ADMIN_ROLE;
        let seedBatchId;

        beforeEach(async function () {
            [deployer, safe, operator, stranger] = await ethers.getSigners();

            // (a) Deploy registry + provenance, then deploy via the timelock path.
            const RegistryFactory = await ethers.getContractFactory("AtsurActorRegistry");
            registry = await upgrades.deployProxy(
                RegistryFactory,
                [deployer.address, operator.address],
                { initializer: "initialize", kind: "uups" }
            );
            await registry.waitForDeployment();

            const ProvenanceFactory = await ethers.getContractFactory("AtsurProvenance");
            provenance = await upgrades.deployProxy(
                ProvenanceFactory,
                [deployer.address, await registry.getAddress(), 1, 1000],
                { initializer: "initialize", kind: "uups" }
            );
            await provenance.waitForDeployment();

            UPGRADER_ROLE      = await provenance.UPGRADER_ROLE();
            DEFAULT_ADMIN_ROLE = await provenance.DEFAULT_ADMIN_ROLE();

            // Seed an actor + a batch BEFORE the upgrade, to later prove existing data survives it.
            const submitterActorId = ethers.keccak256(ethers.toUtf8Bytes("upgrade-flow-submitter"));
            await registry.connect(deployer).registerActor(
                submitterActorId, 0, ethers.keccak256(ethers.toUtf8Bytes("commitment")), "smile_id", stranger.address
            );
            // deployer doesn't hold BATCH_COMMITTER_ROLE by default — grant it temporarily to seed data.
            await provenance.connect(deployer).grantRole(await provenance.BATCH_COMMITTER_ROLE(), deployer.address);
            const merkleRoot  = ethers.keccak256(ethers.toUtf8Bytes("seed-root"));
            const arweaveTxId = ethers.keccak256(ethers.toUtf8Bytes("seed-arweave"));
            const nonce       = ethers.keccak256(ethers.toUtf8Bytes("seed-nonce"));
            const anchorTx    = await provenance.connect(deployer).anchorBatch(
                merkleRoot, arweaveTxId, 1, submitterActorId, nonce, "E12_Production"
            );
            const receipt = await anchorTx.wait();
            const log = receipt.logs
                .map(l => { try { return provenance.interface.parseLog(l); } catch { return null; } })
                .find(e => e && e.name === "BatchAnchored");
            seedBatchId = log.args.batchId;

            // Deploy the timelock (short delay, "safe" signer as proposer + executor) and wire it up.
            timelock = await deployTimelock(safe.address);

            // deployer still holds UPGRADER_ROLE from initialize() and can grant it onward because
            // UPGRADER_ROLE is self-administered (a current holder can transfer it).
            await provenance.connect(deployer).grantRole(UPGRADER_ROLE, await timelock.getAddress());
            await provenance.connect(deployer).revokeRole(UPGRADER_ROLE, deployer.address);

            // Move DEFAULT_ADMIN_ROLE to the "Safe" signer, mirroring production.
            await provenance.connect(deployer).grantRole(DEFAULT_ADMIN_ROLE, safe.address);
            await provenance.connect(deployer).renounceRole(DEFAULT_ADMIN_ROLE, deployer.address);
        });

        it("(b) UPGRADER_ROLE is on the timelock and is self-administered", async function () {
            expect(await provenance.hasRole(UPGRADER_ROLE, await timelock.getAddress())).to.equal(true);
            expect(await provenance.hasRole(UPGRADER_ROLE, deployer.address)).to.equal(false);
            expect(await provenance.getRoleAdmin(UPGRADER_ROLE)).to.equal(UPGRADER_ROLE);
        });

        it("(c) the Safe (DEFAULT_ADMIN_ROLE holder) cannot upgrade directly", async function () {
            const V2Factory = await ethers.getContractFactory("MockProvenanceV2", safe);
            await expect(
                upgrades.upgradeProxy(await provenance.getAddress(), V2Factory)
            ).to.be.reverted;
        });

        it("(d)-(g) schedule -> wait -> execute via the timelock succeeds; execute before the delay reverts", async function () {
            const V2Factory = await ethers.getContractFactory("MockProvenanceV2");
            const newImpl   = await V2Factory.deploy();
            await newImpl.waitForDeployment();

            const proxyAddress = await provenance.getAddress();
            const data = provenance.interface.encodeFunctionData(
                "upgradeToAndCall",
                [await newImpl.getAddress(), "0x"]
            );

            // (d) Schedule the upgrade through the timelock, from the Safe.
            await timelock.connect(safe).schedule(proxyAddress, 0, data, PREDECESSOR, SALT, TIMELOCK_DELAY);

            // (e) Executing before the delay elapses reverts.
            await expect(
                timelock.connect(safe).execute(proxyAddress, 0, data, PREDECESSOR, SALT)
            ).to.be.reverted;

            // (f) Fast-forward past the delay.
            await time.increase(TIMELOCK_DELAY + 1);

            // (g) Execute succeeds once the delay has elapsed.
            await expect(
                timelock.connect(safe).execute(proxyAddress, 0, data, PREDECESSOR, SALT)
            ).to.not.be.reverted;

            // (h) Storage continuity: existing batch data is still readable, and the new field works.
            const upgraded = await ethers.getContractAt("MockProvenanceV2", proxyAddress);
            const batch = await upgraded.getBatch(seedBatchId);
            expect(batch.merkleRoot).to.equal(ethers.keccak256(ethers.toUtf8Bytes("seed-root")));
            expect(await upgraded.minBatchSize()).to.equal(1n);
            expect(await upgraded.maxBatchSize()).to.equal(1000n);

            expect(await upgraded.newField()).to.equal(0n);
            await upgraded.connect(safe).setNewField(42);
            expect(await upgraded.newField()).to.equal(42n);

            // (i) The Safe still cannot grant itself UPGRADER_ROLE after the upgrade —
            // role-admin assignments live in storage and survive the upgrade unchanged.
            await expect(
                upgraded.connect(safe).grantRole(UPGRADER_ROLE, safe.address)
            ).to.be.reverted;
        });
    });

    // ─────────────────────────────────────────────────────────────────────
    // AtsurActorRegistry
    // ─────────────────────────────────────────────────────────────────────
    describe("AtsurActorRegistry", function () {
        let registry, timelock;
        let deployer, safe, operator, actorWallet;
        let UPGRADER_ROLE, DEFAULT_ADMIN_ROLE;
        let seedActorId;

        beforeEach(async function () {
            [deployer, safe, operator, actorWallet] = await ethers.getSigners();

            // (a) Deploy via the timelock path.
            const RegistryFactory = await ethers.getContractFactory("AtsurActorRegistry");
            registry = await upgrades.deployProxy(
                RegistryFactory,
                [deployer.address, operator.address],
                { initializer: "initialize", kind: "uups" }
            );
            await registry.waitForDeployment();

            UPGRADER_ROLE      = await registry.UPGRADER_ROLE();
            DEFAULT_ADMIN_ROLE = await registry.DEFAULT_ADMIN_ROLE();

            // Seed an actor BEFORE the upgrade, to later prove existing data survives it.
            seedActorId = ethers.keccak256(ethers.toUtf8Bytes("upgrade-flow-actor"));
            await registry.connect(operator).registerActor(
                seedActorId, 0, ethers.keccak256(ethers.toUtf8Bytes("commitment")), "smile_id", actorWallet.address
            );

            timelock = await deployTimelock(safe.address);

            await registry.connect(deployer).grantRole(UPGRADER_ROLE, await timelock.getAddress());
            await registry.connect(deployer).revokeRole(UPGRADER_ROLE, deployer.address);

            await registry.connect(deployer).grantRole(DEFAULT_ADMIN_ROLE, safe.address);
            await registry.connect(deployer).renounceRole(DEFAULT_ADMIN_ROLE, deployer.address);
        });

        it("(b) UPGRADER_ROLE is on the timelock and is self-administered", async function () {
            expect(await registry.hasRole(UPGRADER_ROLE, await timelock.getAddress())).to.equal(true);
            expect(await registry.hasRole(UPGRADER_ROLE, deployer.address)).to.equal(false);
            expect(await registry.getRoleAdmin(UPGRADER_ROLE)).to.equal(UPGRADER_ROLE);
        });

        it("(c) the Safe (DEFAULT_ADMIN_ROLE holder) cannot upgrade directly", async function () {
            const V2Factory = await ethers.getContractFactory("MockRegistryV2", safe);
            await expect(
                upgrades.upgradeProxy(await registry.getAddress(), V2Factory)
            ).to.be.reverted;
        });

        it("(d)-(i) full schedule -> wait -> execute upgrade cycle, storage continuity, and post-upgrade lockout", async function () {
            const V2Factory = await ethers.getContractFactory("MockRegistryV2");
            const newImpl   = await V2Factory.deploy();
            await newImpl.waitForDeployment();

            const proxyAddress = await registry.getAddress();
            const data = registry.interface.encodeFunctionData(
                "upgradeToAndCall",
                [await newImpl.getAddress(), "0x"]
            );

            // (d) Schedule
            await timelock.connect(safe).schedule(proxyAddress, 0, data, PREDECESSOR, SALT, TIMELOCK_DELAY);

            // (e) Execute before delay reverts
            await expect(
                timelock.connect(safe).execute(proxyAddress, 0, data, PREDECESSOR, SALT)
            ).to.be.reverted;

            // (f) Fast-forward
            await time.increase(TIMELOCK_DELAY + 1);

            // (g) Execute succeeds
            await expect(
                timelock.connect(safe).execute(proxyAddress, 0, data, PREDECESSOR, SALT)
            ).to.not.be.reverted;

            // (h) Storage continuity
            const upgraded = await ethers.getContractAt("MockRegistryV2", proxyAddress);
            const actor = await upgraded.getActor(seedActorId);
            expect(actor.custodialWallet).to.equal(actorWallet.address);
            expect(actor.registeredAt).to.not.equal(0n);

            expect(await upgraded.newField()).to.equal(0n);
            await upgraded.connect(safe).setNewField(7);
            expect(await upgraded.newField()).to.equal(7n);

            // (i) Safe still cannot self-grant UPGRADER_ROLE after the upgrade
            await expect(
                upgraded.connect(safe).grantRole(UPGRADER_ROLE, safe.address)
            ).to.be.reverted;
        });
    });
});
