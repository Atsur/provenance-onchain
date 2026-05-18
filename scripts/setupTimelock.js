/**
 * setupTimelock.js — Post-deployment TimelockController setup
 *
 * Deploys a TimelockController and transfers UPGRADER_ROLE on AtsurActorRegistry
 * and AtsurProvenance to it. Use this on existing deployments where the contracts
 * were deployed without TIMELOCK_DELAY set.
 *
 * After this script runs, any contract upgrade must be:
 *   1. Proposed to the TimelockController by a proposer (multisig)
 *   2. Waited for the delay to elapse
 *   3. Executed by an executor (multisig)
 *
 * Usage:
 *   npx hardhat run scripts/setupTimelock.js --network liskSepolia
 *
 * Required .env:
 *   PRIVATE_KEY          Admin private key (must hold DEFAULT_ADMIN_ROLE on both contracts)
 *   REGISTRY_ADDRESS     AtsurActorRegistry proxy address
 *   PROVENANCE_ADDRESS   AtsurProvenance proxy address
 *   TIMELOCK_DELAY       Delay in seconds (e.g. 86400 = 24h)
 *   MULTISIG_ADDRESS     Gnosis Safe — proposer and executor of the timelock
 *
 * Optional:
 *   REVOKE_ADMIN_UPGRADER  Set to "true" to also revoke UPGRADER_ROLE from the admin/deployer
 *                          after granting it to the timelock. Default: true.
 */

const hre = require("hardhat");
const { ethers } = hre;
require("dotenv").config();

async function main() {
    const [admin] = await ethers.getSigners();

    const registryAddress  = process.env.REGISTRY_ADDRESS;
    const provenanceAddress = process.env.PROVENANCE_ADDRESS;
    const multisig          = process.env.MULTISIG_ADDRESS;
    const timelockDelay     = process.env.TIMELOCK_DELAY ? parseInt(process.env.TIMELOCK_DELAY, 10) : null;
    const revokeAdmin       = process.env.REVOKE_ADMIN_UPGRADER !== "false"; // default true

    if (!registryAddress)   throw new Error("REGISTRY_ADDRESS not set");
    if (!provenanceAddress) throw new Error("PROVENANCE_ADDRESS not set");
    if (!multisig)          throw new Error("MULTISIG_ADDRESS not set — timelock needs a proposer/executor");
    if (timelockDelay == null) throw new Error("TIMELOCK_DELAY not set (seconds, e.g. 86400)");

    const registry  = await ethers.getContractAt("AtsurActorRegistry", registryAddress);
    const provenance = await ethers.getContractAt("AtsurProvenance", provenanceAddress);
    const UPGRADER_ROLE = await registry.UPGRADER_ROLE();

    console.log("=== Atsur Timelock Setup ===");
    console.log("Admin:          ", admin.address);
    console.log("Registry:       ", registryAddress);
    console.log("Provenance:     ", provenanceAddress);
    console.log("Multisig:       ", multisig);
    console.log("Timelock delay: ", `${timelockDelay}s (${(timelockDelay / 3600).toFixed(1)}h)`);
    console.log("Revoke admin:   ", revokeAdmin);
    console.log("");

    // Verify admin holds DEFAULT_ADMIN_ROLE on both contracts
    const DEFAULT_ADMIN_ROLE = await registry.DEFAULT_ADMIN_ROLE();
    const hasAdminRegistry   = await registry.hasRole(DEFAULT_ADMIN_ROLE, admin.address);
    const hasAdminProvenance = await provenance.hasRole(DEFAULT_ADMIN_ROLE, admin.address);
    if (!hasAdminRegistry || !hasAdminProvenance) {
        throw new Error(
            `Signer ${admin.address} does not hold DEFAULT_ADMIN_ROLE on both contracts.\n` +
            `Registry: ${hasAdminRegistry}, Provenance: ${hasAdminProvenance}`
        );
    }

    // ─── 1. Deploy TimelockController ──────────────────────────────
    console.log("[1] Deploying TimelockController...");
    const TimelockFactory = await ethers.getContractFactory("TimelockController");
    const timelock = await TimelockFactory.deploy(
        timelockDelay,
        [multisig],          // proposers — who can schedule upgrades
        [multisig],          // executors — who can execute after delay
        ethers.ZeroAddress   // self-administration disabled
    );
    await timelock.waitForDeployment();
    const timelockAddress = await timelock.getAddress();
    console.log("  TimelockController:", timelockAddress);

    // ─── 2. Grant UPGRADER_ROLE to timelock ────────────────────────
    console.log("\n[2] Granting UPGRADER_ROLE to TimelockController...");
    let tx = await registry.grantRole(UPGRADER_ROLE, timelockAddress);
    await tx.wait();
    console.log("  ✓ Registry UPGRADER_ROLE -> timelock");

    tx = await provenance.grantRole(UPGRADER_ROLE, timelockAddress);
    await tx.wait();
    console.log("  ✓ Provenance UPGRADER_ROLE -> timelock");

    // ─── 3. Revoke UPGRADER_ROLE from admin (optional) ─────────────
    if (revokeAdmin) {
        console.log("\n[3] Revoking UPGRADER_ROLE from admin...");
        tx = await registry.revokeRole(UPGRADER_ROLE, admin.address);
        await tx.wait();
        console.log("  ✓ Registry UPGRADER_ROLE revoked from admin");

        tx = await provenance.revokeRole(UPGRADER_ROLE, admin.address);
        await tx.wait();
        console.log("  ✓ Provenance UPGRADER_ROLE revoked from admin");
    }

    // ─── Verify ────────────────────────────────────────────────────
    console.log("\n=== Verification ===");
    const checks = await Promise.all([
        registry.hasRole(UPGRADER_ROLE, timelockAddress),
        provenance.hasRole(UPGRADER_ROLE, timelockAddress),
        registry.hasRole(UPGRADER_ROLE, admin.address),
        provenance.hasRole(UPGRADER_ROLE, admin.address),
    ]);
    console.log("Registry  UPGRADER_ROLE -> timelock:", checks[0] ? "✓" : "✗");
    console.log("Provenance UPGRADER_ROLE -> timelock:", checks[1] ? "✓" : "✗");
    console.log("Registry  UPGRADER_ROLE -> admin:   ", checks[2] ? "⚠ still set" : "✓ revoked");
    console.log("Provenance UPGRADER_ROLE -> admin:  ", checks[3] ? "⚠ still set" : "✓ revoked");

    console.log("\n=== Complete ===");
    console.log("TimelockController:", timelockAddress);
    console.log("Delay:            ", `${timelockDelay}s`);
    console.log("Proposers:        ", multisig);
    console.log("Executors:        ", multisig);
    console.log("\nAdd to .env:");
    console.log(`TIMELOCK_ADDRESS=${timelockAddress}`);
    console.log("\nTo propose an upgrade, use the Safe Transaction Builder to call:");
    console.log("  TimelockController.schedule(proxy, 0, upgradeCalldata, 0, salt, delay)");
    console.log("  TimelockController.execute(proxy, 0, upgradeCalldata, 0, salt)");
}

main()
    .then(() => process.exit(0))
    .catch((err) => { console.error(err); process.exit(1); });
