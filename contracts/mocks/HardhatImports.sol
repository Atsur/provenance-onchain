// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

// Hardhat only compiles contracts reachable from an import somewhere under `contracts/`.
// TimelockController is deployed by name (ethers.getContractFactory("TimelockController")) in
// scripts/deployAll.js, scripts/setupTimelock.js, and test/UpgradeFlow.test.js, but nothing
// otherwise imports it — this file exists purely to pull its artifact into the build so those
// `getContractFactory` calls resolve. Foundry doesn't need this; it compiles every file under
// `contracts/` regardless of the import graph.
import "@openzeppelin/contracts/governance/TimelockController.sol";
