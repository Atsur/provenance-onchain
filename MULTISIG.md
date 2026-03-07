# Safe Multisig Setup for Atsur

This guide walks you through creating a Safe (Gnosis Safe) multisig wallet on Lisk Sepolia,
using it as the admin for both Atsur contracts, and making admin transactions through the Safe UI.

---

## Why a Multisig?

The `DEFAULT_ADMIN_ROLE` in both `AtsurActorRegistry` and `AtsurProvenance` controls:
- Granting / revoking operator and pauser roles
- Upgrading contracts (UUPS `_authorizeUpgrade`)
- Changing the actor registry address in AtsurProvenance
- Setting batch size limits

Holding admin in a single private key is a single point of failure. A Safe requires M-of-N
signatures before any of the above actions execute, making the system far more resilient.

**Recommendation for testnet:** 2-of-3 threshold with your team's wallets.
**Recommendation for mainnet:** 3-of-5 threshold with hardware wallets (Ledger / Trezor).

---

## Part 1 — Create a Safe on Lisk Sepolia

### Step 1: Add Lisk Sepolia to your MetaMask

1. Open MetaMask → Settings → Networks → Add Network → Add manually.
2. Fill in:
   - **Network Name:** Lisk Sepolia
   - **RPC URL:** `https://rpc.sepolia-api.lisk.com`
   - **Chain ID:** `4202`
   - **Currency Symbol:** `ETH`
   - **Block Explorer:** `https://sepolia-blockscout.lisk.com`
3. Save and switch to Lisk Sepolia.

### Step 2: Get testnet ETH

Use the Lisk Sepolia faucet or bridge from Sepolia:
- Lisk faucet: https://docs.lisk.com/building-on-lisk/connecting-to-a-faucet
- Or bridge ETH from Ethereum Sepolia via the Lisk bridge portal.

### Step 3: Open Safe{Wallet}

1. Go to https://app.safe.global
2. Click **Create new Safe**.
3. In the network selector (top-left), choose **Lisk Sepolia** (chain ID 4202).
   - If Lisk Sepolia is not in the list, use the custom network option and enter chain ID `4202`.

### Step 4: Configure owners and threshold

1. Add owner wallets (at least 2 for testnet, 4+ for mainnet).
   - These are the MetaMask / hardware wallet addresses of your team members.
2. Set the threshold (e.g., 2-of-3 — meaning 2 signatures needed out of 3 owners).
3. Click **Next**.

### Step 5: Deploy the Safe

1. Review the setup on the summary screen.
2. Click **Create Safe** — this sends a transaction from your connected wallet.
3. Confirm in MetaMask and wait for the transaction to confirm.
4. You will be taken to your new Safe dashboard. Note the **Safe address** — it looks like a normal
   Ethereum address (0x...). **Copy this address.**

---

## Part 2 — Use the Safe Address in Deployment

### Step 1: Add to your .env

```
MULTISIG_ADDRESS=0xYourSafeAddressHere
```

### Step 2: Deploy with the deploy script

```bash
# Foundry
forge script scripts/Deploy.s.sol \
  --rpc-url $LISK_SEPOLIA_RPC \
  --broadcast \
  --verify \
  --verifier blockscout \
  --verifier-url https://sepolia-blockscout.lisk.com/api

# OR Hardhat
npx hardhat run scripts/deployAll.js --network liskSepolia
```

The script will:
1. Deploy both contracts with you (deployer) as initial admin.
2. Grant `BATCH_COMMITTER_ROLE` and `PAUSER_ROLE` to the operator address.
3. **If `MULTISIG_ADDRESS` is set:** grant `DEFAULT_ADMIN_ROLE` to the Safe, then renounce the
   deployer's admin role. After this, only the Safe can perform admin actions.

---

## Part 3 — Making Admin Transactions Through the Safe UI

After deployment, the Safe is the sole admin. Any privileged call must go through Safe.

### Example: Grant a new operator role

1. Open https://app.safe.global and connect your wallet.
2. Select your Safe.
3. Click **New Transaction → Contract Interaction**.
4. Paste the contract address (e.g., AtsurProvenance proxy address).
5. Paste the ABI or use the ABI JSON from `artifacts/contracts/AtsurProvenance.sol/AtsurProvenance.json`.
6. Select the function `grantRole`.
7. Fill in:
   - `role`: the `BATCH_COMMITTER_ROLE` bytes32 value
     (run `cast call <proxy> "BATCH_COMMITTER_ROLE()(bytes32)" --rpc-url $RPC` to get it)
   - `account`: the new operator address
8. Click **Add to batch** → **Create Batch** → **Send Batch**.
9. The other Safe owners will see the pending transaction in their Safe dashboard.
10. Each owner approves by clicking **Confirm** and signing with MetaMask.
11. Once the threshold is reached, anyone can click **Execute** to submit the transaction on-chain.

### Getting role bytes32 values

```bash
# BATCH_COMMITTER_ROLE
cast call <PROVENANCE_PROXY> "BATCH_COMMITTER_ROLE()(bytes32)" --rpc-url $LISK_SEPOLIA_RPC

# OPERATOR_ROLE (registry)
cast call <REGISTRY_PROXY> "OPERATOR_ROLE()(bytes32)" --rpc-url $LISK_SEPOLIA_RPC

# PAUSER_ROLE
cast call <PROVENANCE_PROXY> "PAUSER_ROLE()(bytes32)" --rpc-url $LISK_SEPOLIA_RPC
```

---

## Part 4 — Upgrading Contracts Through the Safe

UUPS upgrades require the admin (your Safe) to call `upgradeToAndCall` on the proxy.

### Step 1: Deploy new implementation

```bash
# Deploy just the implementation (no proxy this time)
forge create contracts/AtsurProvenance.sol:AtsurProvenance \
  --rpc-url $LISK_SEPOLIA_RPC \
  --private-key $PRIVATE_KEY
```

Note the new implementation address from the output.

### Step 2: Prepare the upgrade call

The UUPS `upgradeToAndCall(address newImpl, bytes calldata data)` call must come from the Safe.
If you have no initializer to call during upgrade, use `data = 0x` (empty bytes).

```bash
# Encode the call if you need to call a function during upgrade
cast calldata "upgradeToAndCall(address,bytes)" <NEW_IMPL_ADDR> 0x
```

### Step 3: Queue through Safe UI

1. Open Safe → New Transaction → Contract Interaction.
2. Paste the **proxy** address (not the implementation).
3. Select function `upgradeToAndCall`.
4. Fill in:
   - `newImplementation`: new impl address
   - `data`: `0x` (or encoded calldata if calling a migration function)
5. Create the transaction, collect signatures from owners, and execute.

### Alternative: Use OpenZeppelin Defender for upgrades

OZ Defender has first-class Safe support and a managed upgrade workflow. Worth using when you
go to mainnet. See https://defender.openzeppelin.com for setup.

---

## Part 5 — Safe Tips and Security Checklist

- [ ] Test your Safe on testnet before relying on it for mainnet admin.
- [ ] Ensure at least one owner has a hardware wallet (Ledger / Trezor).
- [ ] Never store all owner private keys on the same machine.
- [ ] Keep the threshold at least 2 (so a single compromised key cannot take admin).
- [ ] For mainnet, use a 3-of-5 or higher threshold.
- [ ] Document which team member holds each owner key.
- [ ] Verify the Safe address on the block explorer before transferring admin.
- [ ] After deploying, confirm `hasRole(DEFAULT_ADMIN_ROLE, safeAddress)` returns true.
- [ ] Confirm `hasRole(DEFAULT_ADMIN_ROLE, deployerAddress)` returns false (renounced).

### Verify roles after deployment

```bash
# Check Safe has admin
cast call <REGISTRY_PROXY> \
  "hasRole(bytes32,address)(bool)" \
  $(cast call <REGISTRY_PROXY> "DEFAULT_ADMIN_ROLE()(bytes32)" --rpc-url $RPC) \
  $MULTISIG_ADDRESS \
  --rpc-url $LISK_SEPOLIA_RPC

# Should return: true
```

---

## Addresses to Record After Deployment

Keep a record of these in a secure, shared location (e.g., your team's password manager):

```
Network:           Lisk Sepolia (chainId 4202)
AtsurActorRegistry proxy:  0x...
AtsurProvenance proxy:     0x...
Safe (multisig) address:   0x...
Operator (hot wallet):     0x...
Deployer:                  0x...
```
