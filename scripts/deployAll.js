/**
 * deployAll.js — Hardhat deploy script for Lisk Sepolia / Lisk Mainnet
 *
 * Deploys AtsurActorRegistry and AtsurProvenance as UUPS proxies using
 * @openzeppelin/hardhat-upgrades for proxy management.
 *
 * Usage:
 *   npx hardhat run scripts/deployAll.js --network liskSepolia
 *
 * Required .env:
 *   PRIVATE_KEY            Deployer private key
 *   OPERATOR_ADDRESS       Hot wallet — OPERATOR_ROLE / BATCH_COMMITTER_ROLE
 *   PAUSER_ADDRESS         Emergency pauser — PAUSER_ROLE (optional, defaults to deployer)
 *   MULTISIG_ADDRESS       Gnosis Safe — receives DEFAULT_ADMIN_ROLE (optional but required for mainnet)
 *   TIMELOCK_DELAY         Upgrade delay in seconds — deploys TimelockController and grants UPGRADER_ROLE
 *                          to it (optional; recommended: 86400 for testnet, 172800+ for mainnet).
 *                          If not set, UPGRADER_ROLE stays with the admin (less safe).
 *   CONFIRM_MAINNET        Must equal "I_UNDERSTAND_THIS_IS_MAINNET" to deploy to a known mainnet
 *                          chain ID (Polygon 137, Lisk 1135).
 */

const { ethers, upgrades } = require("hardhat");
require("dotenv").config();
const { syncDeployment } = require("./syncDeployment");

// Known mainnet chain IDs — deploying here requires CONFIRM_MAINNET (see _checkMainnetConfirmation).
const MAINNET_CHAIN_IDS = [137n, 1135n]; // Polygon, Lisk

async function _checkMainnetConfirmation() {
    const network = await ethers.provider.getNetwork();
    if (MAINNET_CHAIN_IDS.includes(network.chainId)) {
        if (process.env.CONFIRM_MAINNET !== "I_UNDERSTAND_THIS_IS_MAINNET") {
            throw new Error("Set CONFIRM_MAINNET=I_UNDERSTAND_THIS_IS_MAINNET to deploy to mainnet");
        }
    }
}

async function main() {
    await _checkMainnetConfirmation();

    const [deployer] = await ethers.getSigners();

    const operator      = process.env.OPERATOR_ADDRESS
        || (console.warn("⚠ OPERATOR_ADDRESS not set, using deployer"), deployer.address);
    const pauser        = process.env.PAUSER_ADDRESS   || deployer.address;
    const multisig      = process.env.MULTISIG_ADDRESS || null;
    const timelockDelay = process.env.TIMELOCK_DELAY   ? parseInt(process.env.TIMELOCK_DELAY, 10) : null;

    const MIN_BATCH_SIZE = 1;
    const MAX_BATCH_SIZE = 1000;

    console.log("=== Atsur Deployment ===");
    console.log("Deployer:       ", deployer.address);
    console.log("Operator:       ", operator);
    console.log("Pauser:         ", pauser);
    console.log("Multisig:       ", multisig      || "NOT SET (deployer retains admin)");
    console.log("Timelock delay: ", timelockDelay != null ? `${timelockDelay}s` : "NOT SET (no timelock)");
    console.log("Network:        ", (await ethers.provider.getNetwork()).name);
    console.log("");

    // ─── 1. Deploy AtsurActorRegistry ──────────────────────────────
    console.log("[1/2] Deploying AtsurActorRegistry...");
    const RegistryFactory = await ethers.getContractFactory("AtsurActorRegistry");
    const registry = await upgrades.deployProxy(
        RegistryFactory,
        [deployer.address, operator],
        { initializer: "initialize", kind: "uups" }
    );
    await registry.waitForDeployment();
    const registryAddress = await registry.getAddress();
    console.log("  proxy:", registryAddress);
    console.log("  ver:  ", await registry.version());

    // ─── 2. Deploy AtsurProvenance ──────────────────────────────────
    console.log("\n[2/2] Deploying AtsurProvenance...");
    const ProvenanceFactory = await ethers.getContractFactory("AtsurProvenance");
    const provenance = await upgrades.deployProxy(
        ProvenanceFactory,
        [deployer.address, registryAddress, MIN_BATCH_SIZE, MAX_BATCH_SIZE],
        { initializer: "initialize", kind: "uups" }
    );
    await provenance.waitForDeployment();
    const provenanceAddress = await provenance.getAddress();
    console.log("  proxy:", provenanceAddress);
    console.log("  ver:  ", await provenance.version());

    // ─── 3. Grant roles ─────────────────────────────────────────────
    console.log("\n[3] Granting roles...");

    const BATCH_COMMITTER_ROLE = await provenance.BATCH_COMMITTER_ROLE();
    const PAUSER_ROLE          = await provenance.PAUSER_ROLE();

    let tx = await provenance.grantRole(BATCH_COMMITTER_ROLE, operator);
    await tx.wait();
    console.log("  ✓ BATCH_COMMITTER_ROLE -> operator");

    tx = await provenance.grantRole(PAUSER_ROLE, pauser);
    await tx.wait();
    console.log("  ✓ PAUSER_ROLE          -> pauser");

    // ─── 4. Deploy TimelockController and wire UPGRADER_ROLE (if delay set) ──
    let timelockAddress = null;
    if (timelockDelay != null) {
        console.log(`\n[4] Deploying TimelockController (delay=${timelockDelay}s)...`);

        // proposers + executors: multisig if set, otherwise deployer (MUST be updated before mainnet)
        const timelockAdmin = multisig || deployer.address;
        const TimelockFactory = await ethers.getContractFactory("TimelockController");
        const timelock = await TimelockFactory.deploy(
            timelockDelay,
            [timelockAdmin],   // proposers — who can schedule upgrades
            [timelockAdmin],   // executors — who can execute after delay
            ethers.ZeroAddress // self-administration disabled
        );
        await timelock.waitForDeployment();
        timelockAddress = await timelock.getAddress();
        console.log("  TimelockController:", timelockAddress);

        const UPGRADER_ROLE = await registry.UPGRADER_ROLE();

        console.log("  Granting UPGRADER_ROLE to timelock on registry...");
        tx = await registry.grantRole(UPGRADER_ROLE, timelockAddress);
        await tx.wait();

        console.log("  Granting UPGRADER_ROLE to timelock on provenance...");
        tx = await provenance.grantRole(UPGRADER_ROLE, timelockAddress);
        await tx.wait();

        console.log("  Revoking UPGRADER_ROLE from deployer...");
        tx = await registry.revokeRole(UPGRADER_ROLE, deployer.address);
        await tx.wait();
        tx = await provenance.revokeRole(UPGRADER_ROLE, deployer.address);
        await tx.wait();

        console.log("  ✓ Upgrades now require TimelockController proposal + delay.");
    }

    // ─── 5. Transfer admin to multisig (if set) ─────────────────────
    if (multisig) {
        console.log("\n[5] Transferring DEFAULT_ADMIN_ROLE to multisig...");

        const multisigCode = await ethers.provider.getCode(multisig);
        if (multisigCode === "0x") {
            throw new Error("MULTISIG_ADDRESS is an EOA, not a contract. Deploy a Gnosis Safe first.");
        }

        const DEFAULT_ADMIN_ROLE = await registry.DEFAULT_ADMIN_ROLE();

        tx = await registry.grantRole(DEFAULT_ADMIN_ROLE, multisig);
        await tx.wait();
        tx = await provenance.grantRole(DEFAULT_ADMIN_ROLE, multisig);
        await tx.wait();
        tx = await registry.renounceRole(DEFAULT_ADMIN_ROLE, deployer.address);
        await tx.wait();
        tx = await provenance.renounceRole(DEFAULT_ADMIN_ROLE, deployer.address);
        await tx.wait();

        if (!timelockDelay) {
            // UPGRADER_ROLE still held by deployer — transfer it to multisig too
            const UPGRADER_ROLE = await registry.UPGRADER_ROLE();
            tx = await registry.grantRole(UPGRADER_ROLE, multisig);
            await tx.wait();
            tx = await provenance.grantRole(UPGRADER_ROLE, multisig);
            await tx.wait();
            tx = await registry.revokeRole(UPGRADER_ROLE, deployer.address);
            await tx.wait();
            tx = await provenance.revokeRole(UPGRADER_ROLE, deployer.address);
            await tx.wait();
        }

        console.log("  ✓ Admin transferred to multisig. Deployer admin renounced.");
    }

    // ─── 6. Save & sync deployment manifest ─────────────────────────
    const networkInfo = await ethers.provider.getNetwork();
    const chainId     = networkInfo.chainId.toString();
    const manifest = {
        network:    networkInfo.name,
        chainId,
        deployedAt: new Date().toISOString(),
        contracts: {
            AtsurActorRegistry: { proxy: registryAddress },
            AtsurProvenance:    { proxy: provenanceAddress },
            ...(timelockAddress ? { TimelockController: { address: timelockAddress, delaySeconds: timelockDelay } } : {}),
        },
        roles: {
            deployer:  deployer.address,
            operator,
            pauser,
            ...(multisig       ? { multisig }                            : {}),
            ...(timelockAddress ? { upgrader: timelockAddress }           : {}),
        },
    };
    console.log("\n[6] Saving deployment manifest...");
    syncDeployment(manifest, `${chainId}.json`);

    // ─── Summary ────────────────────────────────────────────────────
    console.log("\n=== Deployment Complete ===");
    console.log("AtsurActorRegistry proxy: ", registryAddress);
    console.log("AtsurProvenance proxy:    ", provenanceAddress);
    console.log("\nAdd to .env:");
    console.log(`REGISTRY_ADDRESS=${registryAddress}`);
    console.log(`PROVENANCE_ADDRESS=${provenanceAddress}`);

    if (!multisig) {
        console.log("\n⚠  MULTISIG_ADDRESS not set — deployer retains DEFAULT_ADMIN_ROLE.");
        console.log("   Set up a Gnosis Safe and re-run grantRoles.js before mainnet.");
    }
    if (!timelockDelay) {
        console.log("\n⚠  TIMELOCK_DELAY not set — UPGRADER_ROLE held by admin/multisig directly.");
        console.log("   Run scripts/setupTimelock.js to add upgrade delay before mainnet.");
    }

    return { registry, provenance };
}

main()
    .then(() => process.exit(0))
    .catch((err) => { console.error(err); process.exit(1); });
