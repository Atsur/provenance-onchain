/**
 * deployAll.js — Hardhat deploy script for Lisk Sepolia
 *
 * Deploys AtsurActorRegistry and AtsurProvenance as UUPS proxies using
 * @openzeppelin/hardhat-upgrades for proxy management.
 *
 * Usage:
 *   npx hardhat run scripts/deployAll.js --network liskSepolia
 *
 * Required .env:
 *   PRIVATE_KEY          Deployer private key
 *   OPERATOR_ADDRESS     Hot wallet — OPERATOR_ROLE / BATCH_COMMITTER_ROLE
 *   PAUSER_ADDRESS       Emergency pauser — PAUSER_ROLE (optional, defaults to deployer)
 *   MULTISIG_ADDRESS     Safe multisig (optional — admin transferred if set)
 */

const { ethers, upgrades } = require("hardhat");
require("dotenv").config();
const { syncDeployment } = require("./syncDeployment");

async function main() {
    const [deployer] = await ethers.getSigners();

    const operator = process.env.OPERATOR_ADDRESS
        || (console.warn("⚠ OPERATOR_ADDRESS not set, using deployer"), deployer.address);
    const pauser   = process.env.PAUSER_ADDRESS   || deployer.address;
    const multisig = process.env.MULTISIG_ADDRESS || null;

    const MIN_BATCH_SIZE = 1;
    const MAX_BATCH_SIZE = 1000;

    console.log("=== Atsur Deployment (Lisk Sepolia) ===");
    console.log("Deployer: ", deployer.address);
    console.log("Operator: ", operator);
    console.log("Pauser:   ", pauser);
    console.log("Multisig: ", multisig || "NOT SET");
    console.log("Network:  ", (await ethers.provider.getNetwork()).name);
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

    // ─── 4. Transfer admin to multisig (if set) ─────────────────────
    if (multisig) {
        console.log("\n[4] Transferring DEFAULT_ADMIN_ROLE to multisig...");
        const DEFAULT_ADMIN_ROLE = await registry.DEFAULT_ADMIN_ROLE();

        tx = await registry.grantRole(DEFAULT_ADMIN_ROLE, multisig);
        await tx.wait();
        tx = await provenance.grantRole(DEFAULT_ADMIN_ROLE, multisig);
        await tx.wait();
        tx = await registry.renounceRole(DEFAULT_ADMIN_ROLE, deployer.address);
        await tx.wait();
        tx = await provenance.renounceRole(DEFAULT_ADMIN_ROLE, deployer.address);
        await tx.wait();

        console.log("  ✓ Admin transferred to multisig. Deployer admin renounced.");
    }

    // ─── 5. Save & sync deployment manifest ─────────────────────────
    const networkInfo = await ethers.provider.getNetwork();
    const chainId     = networkInfo.chainId.toString();
    const manifest = {
        network:    networkInfo.name,
        chainId,
        deployedAt: new Date().toISOString(),
        contracts: {
            AtsurActorRegistry: { proxy: registryAddress },
            AtsurProvenance:    { proxy: provenanceAddress },
        },
        roles: {
            deployer:  deployer.address,
            operator,
            pauser,
            ...(multisig ? { multisig } : {}),
        },
    };
    console.log("\n[5] Saving deployment manifest...");
    syncDeployment(manifest, `${chainId}.json`);

    // ─── Summary ────────────────────────────────────────────────────
    console.log("\n=== Deployment Complete ===");
    console.log("AtsurActorRegistry proxy: ", registryAddress);
    console.log("AtsurProvenance proxy:    ", provenanceAddress);
    console.log("\nAdd to .env:");
    console.log(`REGISTRY_ADDRESS=${registryAddress}`);
    console.log(`PROVENANCE_ADDRESS=${provenanceAddress}`);

    if (!multisig) {
        console.log("\n⚠ Admin not transferred — see MULTISIG.md to set up Safe before mainnet.");
    }

    return { registry, provenance };
}

main()
    .then(() => process.exit(0))
    .catch((err) => { console.error(err); process.exit(1); });
