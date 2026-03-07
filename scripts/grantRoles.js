/**
 * grantRoles.js — Grant roles on AtsurActorRegistry and AtsurProvenance
 *
 * Usage:
 *   npx hardhat run scripts/grantRoles.js --network liskSepolia
 *
 * Required .env:
 *   REGISTRY_ADDRESS       AtsurActorRegistry proxy
 *   PROVENANCE_ADDRESS     AtsurProvenance proxy
 *   OPERATOR_ADDRESS       Receives OPERATOR_ROLE (registry) and BATCH_COMMITTER_ROLE (provenance)
 *   PAUSER_ADDRESS         Receives PAUSER_ROLE on provenance (optional, defaults to operator)
 */

const hre = require("hardhat");
require("dotenv").config();

async function main() {
    const [deployer] = await hre.ethers.getSigners();

    const registryAddress  = process.env.REGISTRY_ADDRESS;
    const provenanceAddress = process.env.PROVENANCE_ADDRESS;
    const operator          = process.env.OPERATOR_ADDRESS;
    const pauser            = process.env.PAUSER_ADDRESS || operator;

    if (!registryAddress)  throw new Error("REGISTRY_ADDRESS not set");
    if (!provenanceAddress) throw new Error("PROVENANCE_ADDRESS not set");
    if (!operator)          throw new Error("OPERATOR_ADDRESS not set");

    console.log("=== Grant Roles ===");
    console.log("Deployer:  ", deployer.address);
    console.log("Registry:  ", registryAddress);
    console.log("Provenance:", provenanceAddress);
    console.log("Operator:  ", operator);
    console.log("Pauser:    ", pauser);
    console.log("");

    const registry  = await hre.ethers.getContractAt("AtsurActorRegistry", registryAddress);
    const provenance = await hre.ethers.getContractAt("AtsurProvenance", provenanceAddress);

    // Registry roles
    const OPERATOR_ROLE = await registry.OPERATOR_ROLE();
    console.log("Granting OPERATOR_ROLE on registry...");
    let tx = await registry.grantRole(OPERATOR_ROLE, operator);
    await tx.wait();
    console.log("  ✓ OPERATOR_ROLE -> operator");

    // Provenance roles
    const BATCH_COMMITTER_ROLE = await provenance.BATCH_COMMITTER_ROLE();
    const PAUSER_ROLE          = await provenance.PAUSER_ROLE();

    console.log("Granting BATCH_COMMITTER_ROLE on provenance...");
    tx = await provenance.grantRole(BATCH_COMMITTER_ROLE, operator);
    await tx.wait();
    console.log("  ✓ BATCH_COMMITTER_ROLE -> operator");

    console.log("Granting PAUSER_ROLE on provenance...");
    tx = await provenance.grantRole(PAUSER_ROLE, pauser);
    await tx.wait();
    console.log("  ✓ PAUSER_ROLE -> pauser");

    // Verify
    console.log("\n=== Role Verification ===");
    const checks = await Promise.all([
        registry.hasRole(OPERATOR_ROLE, operator),
        provenance.hasRole(BATCH_COMMITTER_ROLE, operator),
        provenance.hasRole(PAUSER_ROLE, pauser),
    ]);
    console.log("Registry   OPERATOR_ROLE:        ", checks[0] ? "✓" : "✗");
    console.log("Provenance BATCH_COMMITTER_ROLE: ", checks[1] ? "✓" : "✗");
    console.log("Provenance PAUSER_ROLE:          ", checks[2] ? "✓" : "✗");
}

main()
    .then(() => process.exit(0))
    .catch((err) => { console.error(err); process.exit(1); });
