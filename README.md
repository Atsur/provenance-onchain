## ATSUR Registry Onchain

Smart contracts for **immutable, verifiable provenance** of artworks and cultural assets, built on EVM chains with Arweave-backed storage.

### What this repository is

- **On-chain backbone for provenance**: Minimal, gas-efficient contracts that anchor batches of provenance events on-chain while storing full event data on Arweave.
- **Identity + provenance**: A dedicated actor registry (`AtsurActorRegistry`) and a provenance hub (`AtsurProvenance` / `ProvenanceHub`) designed to work together.
- **Implementation of the Atsur whitepaper**: Aligned with the Atsur provenance spec (Merkle batching, Arweave, CIDOC events, authorship checks).

Internal implementation notes, AI design docs, and low-level tuning live in `dev-docs/` and are intentionally excluded from the published repository.

---

## Architecture

- **AtsurActorRegistry**
  - Canonical on-chain identity registry for all actors (artists, collectors, galleries, institutions, delegated verifiers).
  - Stores KYC/KYB commitments and links platform UUIDs to custodial and self-custodial wallets.
  - Supports:
    - Tiered actors (KYC-verified vs delegated verifiers).
    - Wallet linking (custodial → self-custodial).
    - Institutional verifier delegation and revocation.

- **AtsurProvenance / ProvenanceHub**
  - Anchors **Merkle roots** of provenance event batches.
  - References **Arweave transaction IDs** for full batch payloads.
  - Stores event metadata such as `eventType` (CIDOC class) and event count.
  - Exposes a verification surface for:
    - Checking whether a given event leaf is part of a committed batch.
    - Checking simple authorship commitments (Phase 1).

- **Design goals**
  - Minimise on-chain storage; push full event data to Arweave.
  - Keep verification cheap and transparent with Merkle proofs.
  - Separate **identity**, **authorship**, and **provenance** so different institutions can integrate safely.

---

## Repository layout

```text
registry-onchain/
├── contracts/              # Core Solidity contracts
│   ├── AtsurActorRegistry.sol    # Actor / identity registry
│   └── AtsurProvenance.sol      # Provenance hub (batch anchoring + verification)
├── scripts/                # Hardhat deployment and helper scripts
├── test/                   # Hardhat JS tests
├── test/foundry/           # Foundry tests (Solidity-based)
├── docs/                   # Public-facing docs (deployment, multisig, security)
├── dev-docs/               # Internal implementation notes (gitignored)
├── foundry.toml            # Foundry configuration
├── hardhat.config.js       # Hardhat configuration
└── package.json            # Node / Hardhat dependencies
```

---

## Getting started

### Prerequisites

- **Node.js** 18+
- **Foundry** (for Solidity tests and scripts)
- **Hardhat** (already configured via `devDependencies`)
- A supported EVM RPC endpoint (e.g. Lisk Sepolia, Polygon Mumbai) for live deployments.

### Install toolchain and dependencies

```bash
# Install Foundry (if you don't have it)
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
# Using Foundry
forge build

# Using Hardhat
npx hardhat compile
```

### Test

```bash
# Foundry tests (recommended)
forge test

# Hardhat tests
npx hardhat test
```

---

## Running locally

You can run the full stack on a local Hardhat node.

```bash
# 1. Start a local node
npx hardhat node

# 2. In another terminal, deploy local contracts
npm run deploy:local
```

This:

- Deploys `AtsurActorRegistry` and `AtsurProvenance` (or `ProvenanceHub`) to the local network.
- Seeds a small set of test actors and roles.
- Writes deployed addresses (and RPC URL) into `.deployments/31337.json`.

Your backend / CLI / UI can then:

- Read `.deployments/31337.json` to discover contract addresses.
- Connect via `http://127.0.0.1:8545` (`localhost` Hardhat node, chain ID `1337`).

For more detail, see `DEPLOYMENT.md`.

---

## Deploying to public networks

Deployment flows and network-specific details are documented in `DEPLOYMENT.md` and `MULTISIG.md`. At a high level:

- **Testnets**
  - Lisk Sepolia
  - Polygon Mumbai
- **Mainnets (planned)**
  - Lisk Mainnet
  - Polygon Mainnet

The repo supports both:

- **Foundry scripts** (`script/Deploy.s.sol`) for reproducible deployments.
- **Hardhat scripts** in `scripts/` for role setup, seeding, and local workflows.

You must configure environment variables (RPC URLs, deployer keys, explorer API keys) in `.env` as described in `DEPLOYMENT.md`.

---

## Contract surfaces (high-level)

### `AtsurActorRegistry`

- Register KYC/KYB-verified actors (individuals, groups, institutions).
- Link custodial and self-custodial wallets to the same actor ID.
- Delegate and revoke institutional verifiers.
- Update KYC commitments when changing providers.

Access control:

- `DEFAULT_ADMIN_ROLE`: multisig or governance; manages upgrades and roles.
- `OPERATOR_ROLE`: hot wallet used by the Atsur backend for routine operations.

### `AtsurProvenance` / `ProvenanceHub`

- Anchor provenance batches:
  - `anchorBatch(merkleRoot, arweaveTxId, eventCount, eventType)`
- Verify individual events:
  - `verifyProvenanceEvent(batchIndex, leaf, proofPath)` (sorted Merkle proofs).
- Simple authorship checks:
  - `checkAuthorship(artworkId, commitment, presented)`

Roles (via AccessControl):

- `DEFAULT_ADMIN_ROLE`: upgrade authority and role manager.
- `BATCH_COMMITTER_ROLE`: authorised batch submitters.
- `PAUSER_ROLE`: can pause batch commits in emergencies.

See the Solidity Natspec on each contract for the full, precise API.

---

## Security, audits, and usage in production

- **This code is not a substitute for an audit.** While it uses OpenZeppelin libraries, UUPS upgrade patterns, and has extensive tests, you **must** perform your own review and, for serious value, a professional third-party audit.
- **Upgrades and governance**:
  - UUPS proxies mean an admin address can upgrade implementations.
  - You should front this with a hardware-wallet-backed multisig and clear operational policies (see `MULTISIG.md`).
- **Key security practices recommended by the wider ecosystem**:
  - Follow the guidelines in ConsenSys’ [smart-contract-best-practices](https://github.com/Consensys/smart-contract-best-practices).
  - Treat admin keys and upgradeability as critical risks; lock them down accordingly.

For responsible disclosure of vulnerabilities, use the process described in `SECURITY.md`. Do **not** open public GitHub issues for sensitive findings.

---

## Contributing

Contributions are welcome, subject to review.

- Open an issue first for substantial changes to discuss the approach.
- Ensure tests pass (`forge test` and `npx hardhat test` where relevant).
- Follow existing code style and patterns (OpenZeppelin-style Solidity, clear Natspec).

A more detailed contribution guide and issue templates can be added as the project matures and community participation grows.

---

## License

MIT

