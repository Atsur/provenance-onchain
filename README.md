# ATSUR Registry Onchain

EVM-compatible smart contracts for immutable provenance event logging on blockchain.

## Overview

This project implements a Hub-and-Spoke architecture for storing provenance events with minimal on-chain storage. Only Merkle roots are stored on-chain, with full event data stored on Arweave.

## Architecture

- **Hub Contract**: Main contract storing Merkle roots and Arweave transaction IDs
- **UUPS Upgradeable**: Contracts use UUPS proxy pattern for upgradeability
- **Role-Based Access Control**: Supports single address and multi-sig authorization
- **Gas Optimized**: Minimal on-chain storage, efficient Merkle proof verification

## Networks

- **Lisk Sepolia**: Primary testnet (EVM-compatible L2)
- **Polygon Mumbai**: Secondary testnet
- **Lisk Mainnet**: Production deployment (when ready)
- **Polygon Mainnet**: Future production deployment

## Project Structure

```
registry-onchain/
├── contracts/          # Solidity contracts
├── scripts/            # Deployment scripts
├── test/              # Test files
├── foundry.toml       # Foundry configuration
├── hardhat.config.js  # Hardhat configuration
└── package.json       # Node dependencies
```

## Quick Start

### Prerequisites

- Node.js 18+
- Foundry (for testing and deployment)
- Hardhat (for additional tooling)

### Installation

```bash
# Install Foundry
curl -L https://foundry.paradigm.xyz | bash
foundryup

# Install Node dependencies
npm install

# Install Foundry dependencies
forge install OpenZeppelin/openzeppelin-contracts
forge install OpenZeppelin/openzeppelin-contracts-upgradeable
```

### Compile

```bash
forge build
# or
npx hardhat compile
```

### Test

```bash
# Foundry tests (faster, more comprehensive)
forge test

# Hardhat tests
npx hardhat test
```

### Deploy

```bash
# Deploy to Lisk Sepolia
forge script script/Deploy.s.sol:DeployScript --rpc-url $LISK_SEPOLIA_RPC --broadcast --verify

# Deploy to Polygon Mumbai
forge script script/Deploy.s.sol:DeployScript --rpc-url $POLYGON_MUMBAI_RPC --broadcast --verify
```

## Contracts

### ProvenanceHub

Main contract for committing provenance event batches.

**Key Features:**
- Merkle root storage
- Arweave TX ID validation
- Role-based access control
- Pause functionality
- Upgradeable (UUPS)

### Access Control

- **DEFAULT_ADMIN_ROLE**: Full control, can grant/revoke roles
- **BATCH_COMMITTER_ROLE**: Can commit batches
- **PAUSER_ROLE**: Can pause contract operations

## Security

- OpenZeppelin contracts (audited)
- UUPS upgradeable pattern
- Reentrancy guards
- Input validation
- Comprehensive test coverage

## License

MIT

