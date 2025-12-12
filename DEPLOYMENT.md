# Deployment Guide

## Prerequisites

1. **Install Foundry**
   ```bash
   curl -L https://foundry.paradigm.xyz | bash
   foundryup
   ```

2. **Install Node.js dependencies**
   ```bash
   npm install
   ```

3. **Install Foundry dependencies**
   ```bash
   forge install OpenZeppelin/openzeppelin-contracts
   forge install OpenZeppelin/openzeppelin-contracts-upgradeable
   ```

4. **Set up environment variables**
   ```bash
   cp .env.example .env
   # Edit .env with your private keys and RPC URLs
   ```

## Network Configuration

### Lisk Sepolia (Testnet)

- **Chain ID**: 4202
- **RPC URL**: `https://rpc.sepolia-api.lisk.com`
- **Explorer**: `https://sepolia-blockscout.lisk.com`
- **Faucet**: Use Ethereum Sepolia faucet, then bridge to Lisk Sepolia

### Polygon Mumbai (Testnet)

- **Chain ID**: 80001
- **RPC URL**: `https://rpc-mumbai.maticvigil.com`
- **Explorer**: `https://mumbai.polygonscan.com`
- **Faucet**: `https://faucet.polygon.technology/`

## Deployment Steps

### Option 1: Using Foundry (Recommended)

1. **Compile contracts**
   ```bash
   forge build
   ```

2. **Run tests**
   ```bash
   forge test
   ```

3. **Deploy to Lisk Sepolia**
   ```bash
   forge script script/Deploy.s.sol:DeployScript \
     --rpc-url $LISK_SEPOLIA_RPC_URL \
     --broadcast \
     --verify \
     --etherscan-api-key $LISK_SEPOLIA_API_KEY
   ```

4. **Deploy to Polygon Mumbai**
   ```bash
   forge script script/Deploy.s.sol:DeployScript \
     --rpc-url $POLYGON_MUMBAI_RPC_URL \
     --broadcast \
     --verify \
     --etherscan-api-key $POLYGONSCAN_API_KEY
   ```

### Option 2: Using Hardhat

1. **Compile contracts**
   ```bash
   npx hardhat compile
   ```

2. **Run tests**
   ```bash
   npx hardhat test
   ```

3. **Deploy to Lisk Sepolia**
   ```bash
   npx hardhat run scripts/deploy.js --network liskSepolia
   ```

4. **Deploy to Polygon Mumbai**
   ```bash
   npx hardhat run scripts/deploy.js --network polygonMumbai
   ```

## Post-Deployment

### 1. Grant Roles

After deployment, grant roles to authorized addresses:

```bash
# Set environment variables
export HUB_ADDRESS=<deployed_hub_address>
export BATCH_COMMITTER_ADDRESS=<committer_address>
export PAUSER_ADDRESS=<pauser_address>

# Grant roles
npx hardhat run scripts/grantRoles.js --network liskSepolia
```

Or using Foundry:

```solidity
// In a script or via cast
cast send $HUB_ADDRESS \
  "grantRole(bytes32,address)" \
  $(cast sig "BATCH_COMMITTER_ROLE()") \
  $COMMITTER_ADDRESS \
  --rpc-url $LISK_SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY
```

### 2. Verify Contracts

Contracts should auto-verify during deployment. If not:

```bash
# Foundry
forge verify-contract <implementation_address> \
  ProvenanceHub \
  --chain-id 4202 \
  --etherscan-api-key $LISK_SEPOLIA_API_KEY

# Hardhat
npx hardhat verify --network liskSepolia <implementation_address>
```

### 3. Test Batch Commitment

```bash
# Using Hardhat script
npx hardhat run scripts/commitBatch.js --network liskSepolia

# Or interact directly
cast send $HUB_ADDRESS \
  "commitBatch(bytes32,bytes32,uint256)" \
  $MERKLE_ROOT \
  $ARWEAVE_TX_ID \
  500 \
  --rpc-url $LISK_SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY
```

## Configuration

### Batch Size Limits

Default values:
- **Min Batch Size**: 100 events
- **Max Batch Size**: 1000 events

To update (requires admin role):

```bash
cast send $HUB_ADDRESS \
  "setBatchSizeLimits(uint256,uint256)" \
  200 \
  2000 \
  --rpc-url $LISK_SEPOLIA_RPC_URL \
  --private-key $ADMIN_PRIVATE_KEY
```

## Multi-Sig Setup

### Using Gnosis Safe

1. Deploy Gnosis Safe on target network
2. Grant roles to Safe address:
   ```bash
   # Grant admin role
   cast send $HUB_ADDRESS \
     "grantRole(bytes32,address)" \
     $(cast sig "DEFAULT_ADMIN_ROLE()") \
     $SAFE_ADDRESS \
     --rpc-url $RPC_URL \
     --private-key $DEPLOYER_KEY
   ```

3. Use Safe UI to manage roles and upgrades

## Upgrade Process

### 1. Deploy New Implementation

```bash
# Deploy new implementation
forge script script/Upgrade.s.sol:UpgradeScript \
  --rpc-url $RPC_URL \
  --broadcast
```

### 2. Upgrade Proxy

```bash
# Using Hardhat upgrades plugin
npx hardhat run scripts/upgrade.js --network liskSepolia
```

### 3. Verify Upgrade

```bash
# Check implementation address
cast call $HUB_ADDRESS "getImplementation()" --rpc-url $RPC_URL

# Should match new implementation address
```

## Monitoring

### Events to Monitor

- `BatchCommitted`: New batch committed
- `BatchSizeLimitsUpdated`: Configuration changed
- `ProofVerified`: Proof verification (if using event-emitting version)

### Setup Event Monitoring

```javascript
// Example using ethers.js
const hub = new ethers.Contract(hubAddress, hubABI, provider);

hub.on("BatchCommitted", (batchId, merkleRoot, arweaveTxId, eventCount, timestamp, committer) => {
    console.log(`Batch ${batchId} committed: ${eventCount} events`);
});
```

## Security Checklist

- [ ] Contracts verified on block explorer
- [ ] Roles granted to correct addresses
- [ ] Multi-sig configured (if using)
- [ ] Emergency pause tested
- [ ] Upgrade process tested on testnet
- [ ] Event monitoring set up
- [ ] Documentation updated with addresses

## Troubleshooting

### Deployment Fails

- Check RPC URL is correct
- Ensure wallet has enough ETH for gas
- Verify private key is correct

### Verification Fails

- Wait for more block confirmations
- Check API key is correct
- Try manual verification on block explorer

### Role Granting Fails

- Ensure deployer has DEFAULT_ADMIN_ROLE
- Check address is correct
- Verify transaction was successful

## Production Deployment

Before mainnet deployment:

1. **Complete Security Audit**
2. **Test on Testnet Extensively**
3. **Set up Multi-Sig for Admin**
4. **Implement Timelock for Upgrades**
5. **Document All Addresses**
6. **Set up Monitoring and Alerts**
7. **Prepare Emergency Procedures**

## Support

For issues or questions, refer to:
- [Security Documentation](./SECURITY.md)
- [README](./README.md)
- Contract source code and comments

