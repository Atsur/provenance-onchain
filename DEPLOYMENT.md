# Deployment Guide

This guide covers deploying `AtsurActorRegistry` and `AtsurProvenance` as UUPS proxies, both
for testnets and mainnet, and the post-deployment checks you must run before treating a
deployment as production-ready.

Both a Foundry path (`scripts/Deploy.s.sol`) and a Hardhat path (`scripts/deployAll.js`) are
maintained and kept in sync. Pick whichever fits your workflow — they perform the same steps.

---

## 1. Prerequisites

- **Node.js 18+** and **Foundry** (`curl -L https://foundry.paradigm.xyz | bash && foundryup`).
- `npm install` (Hardhat path) and `forge install` / `git submodule update --init --recursive`
  (Foundry path) — see [README.md](README.md) for the exact commands.
- A `.env` file based on [.env.example](.env.example) — copy it and fill in real values. **Never
  commit `.env`.**
- A **funded deployer wallet**. The deployer pays for both contract deployments, the
  `TimelockController` deployment (non-local networks), and all role-granting transactions in
  the same script run.
- **A pre-deployed Gnosis Safe**, if you intend to set `MULTISIG_ADDRESS`. The deploy scripts
  check `multisig.code.length > 0` on-chain and will revert with `"MULTISIG_ADDRESS is an EOA,
  not a contract. Deploy a Gnosis Safe first."` if you pass a plain wallet address instead of a
  deployed Safe. Deploy the Safe first via [safe.global](https://safe.global) (or your own
  tooling) and use its address.
- Decide your **operator** (hot wallet for `anchorBatch`/registry writes) and **pauser**
  (emergency-pause wallet) addresses ahead of time.

---

## 2. Testnet deployment

Testnets currently configured: **Lisk Sepolia** (chain ID 4202). `polygonMumbai` has been
removed from `hardhat.config.js` since Polygon decommissioned it in 2024; use `polygonAmoy`
(chain ID 80002) if you need a Polygon testnet.

On testnets, `MULTISIG_ADDRESS` and `TIMELOCK_DELAY` are optional — but the `TimelockController`
is **always** deployed automatically by `Deploy.s.sol` for any non-local network, testnets
included, with a default 48h delay (172800s) unless you override `TIMELOCK_DELAY` (the script
enforces a 24h/86400s floor on every non-local network).

### Hardhat path

```bash
npx hardhat run scripts/deployAll.js --network liskSepolia
```

Optionally export `TIMELOCK_DELAY` first (e.g. `export TIMELOCK_DELAY=86400`) if you want
`deployAll.js` to also deploy a timelock on the Hardhat path — unlike `Deploy.s.sol`, the
Hardhat script still treats this as opt-in, matching its existing behaviour.

### Foundry path

```bash
forge script scripts/Deploy.s.sol \
  --rpc-url $LISK_SEPOLIA_RPC_URL \
  --broadcast \
  --verify \
  --verifier blockscout \
  --verifier-url https://sepolia-blockscout.lisk.com/api
```

Both scripts print proxy addresses, implementation addresses, and (on non-local networks) the
`TimelockController` address at the end. Copy `REGISTRY_ADDRESS` and `PROVENANCE_ADDRESS` into
your `.env`.

---

## 3. Mainnet deployment

Mainnets configured: **Lisk** (chain ID 1135), **Polygon** (chain ID 137).

Both deploy scripts will **refuse to run against these chain IDs** unless
`CONFIRM_MAINNET=I_UNDERSTAND_THIS_IS_MAINNET` is set in the environment. This is a deliberate
speed bump — there is no other difference in code path between testnet and mainnet deploys.

Before running either command below:

1. Set `MULTISIG_ADDRESS` to your deployed Gnosis Safe (2-of-3 per the intended architecture).
   The script verifies it has code on-chain and reverts otherwise.
2. Set `TIMELOCK_DELAY` to at least `86400`; `172800` (48h) is the recommended production value
   and is also the default if you leave it unset.
3. Set `CONFIRM_MAINNET=I_UNDERSTAND_THIS_IS_MAINNET`.

### Hardhat path

```bash
CONFIRM_MAINNET=I_UNDERSTAND_THIS_IS_MAINNET npx hardhat run scripts/deployAll.js --network lisk
# or --network polygon
```

### Foundry path

```bash
CONFIRM_MAINNET=I_UNDERSTAND_THIS_IS_MAINNET forge script scripts/Deploy.s.sol \
  --rpc-url $LISK_RPC_URL \
  --broadcast \
  --verify
```

On mainnet, `Deploy.s.sol` unconditionally deploys the `TimelockController` (this is not
optional — see [SECURITY.md](SECURITY.md) for why), grants it `UPGRADER_ROLE` on both contracts,
revokes `UPGRADER_ROLE` from the deployer, then transfers `DEFAULT_ADMIN_ROLE` to the Safe and
renounces it from the deployer.

---

## 4. Post-deployment verification checklist

Run through all of these before considering the deployment production-ready. Replace
`$REGISTRY` / `$PROVENANCE` / `$TIMELOCK` / `$SAFE` with the real addresses.

```js
// In a Hardhat console (npx hardhat console --network <network>):
const registry = await ethers.getContractAt("AtsurActorRegistry", "$REGISTRY");
const provenance = await ethers.getContractAt("AtsurProvenance", "$PROVENANCE");

const UPGRADER_ROLE = await registry.UPGRADER_ROLE();
const DEFAULT_ADMIN_ROLE = await registry.DEFAULT_ADMIN_ROLE();
```

- [ ] **Proxy addresses are correct** — `registry.target` / `provenance.target` match what you
      recorded; `registry.version()` / `provenance.version()` return the expected strings.
- [ ] **`UPGRADER_ROLE` is on the timelock, not the deployer**:
      `await registry.hasRole(UPGRADER_ROLE, "$TIMELOCK")` → `true`,
      `await registry.hasRole(UPGRADER_ROLE, deployerAddress)` → `false` (same for `provenance`).
- [ ] **`UPGRADER_ROLE` is self-administered**: confirm `registry.getRoleAdmin(UPGRADER_ROLE) ===
      UPGRADER_ROLE` (same for `provenance`). If this is wrong, the Safe can re-grant itself
      upgrade power and the timelock provides no real protection — do not proceed.
- [ ] **`DEFAULT_ADMIN_ROLE` is on the Safe, not the deployer**:
      `await registry.hasRole(DEFAULT_ADMIN_ROLE, "$SAFE")` → `true`,
      `await registry.hasRole(DEFAULT_ADMIN_ROLE, deployerAddress)` → `false`.
- [ ] **The Safe is actually a contract**: `(await ethers.provider.getCode("$SAFE")) !== "0x"`.
      The deploy script already checks this before granting admin, but verify independently.
- [ ] **Operator and pauser roles landed correctly**: `BATCH_COMMITTER_ROLE` / `OPERATOR_ROLE` on
      the operator hot wallet, `PAUSER_ROLE` on the pauser address — not on the deployer.
- [ ] **Contracts are verified on the block explorer** (Blockscout for Lisk, Polygonscan for
      Polygon) — `--verify` during deploy handles this; if it failed, run
      `npx hardhat verify --network <network> <implementation-address>` manually for each
      implementation contract (not the proxy).

---

## 5. Performing an upgrade

Once deployed, every upgrade must go through the timelock — there is no other path, because
`UPGRADER_ROLE` is self-administered and only the timelock holds it.

1. **Deploy the new implementation contract** (do not deploy a new proxy):
   ```bash
   forge create contracts/AtsurProvenance.sol:AtsurProvenance --rpc-url $RPC_URL --broadcast
   ```
2. **Encode the upgrade call**: `upgradeToAndCall(newImplementation, "")` (or with init data if
   the new version needs a re-initializer).
3. **Schedule via the Safe + timelock**: a Safe signer proposes a transaction that calls
   `TimelockController.schedule(target, 0, upgradeCalldata, predecessor, salt, delay)` where
   `target` is the proxy address. This requires the Safe's normal signing threshold (2-of-3) to
   submit the schedule transaction.
4. **Wait the delay** (48h in production). This window is the entire point of the timelock —
   anyone watching the timelock's pending-operations can review the proposed implementation
   before it goes live.
5. **Execute**: once the delay has elapsed, a Safe signer calls
   `TimelockController.execute(target, 0, upgradeCalldata, predecessor, salt)`. This actually
   calls `upgradeToAndCall` on the proxy, gated by `_authorizeUpgrade`'s `onlyRole(UPGRADER_ROLE)`
   check — which only the timelock satisfies.

There is no separate "upgrade script" beyond the above — it is intentionally a manual,
multi-signer, time-delayed process. Do not attempt to shortcut it by granting `UPGRADER_ROLE`
directly to the Safe; that call itself requires the role-admin of `UPGRADER_ROLE` (i.e.
`UPGRADER_ROLE` itself), so the Safe cannot do this without already controlling the timelock.

---

## 6. Emergency procedures

### Pausing batch commits

`PAUSER_ROLE` can halt `anchorBatch` and the `record*` functions immediately, with **no
timelock delay** — this is intentional (see [SECURITY.md](SECURITY.md) for why a pause is not
itself an upgrade and should not be gated the same way):

```js
await provenance.connect(pauserSigner).pauseBatchCommits();
```

Only `DEFAULT_ADMIN_ROLE` (the Safe) can unpause:

```js
await provenance.connect(safeSigner).unpauseBatchCommits();
```

### Rotating the operator key

If the operator hot wallet is compromised, revoke its roles and grant the new key immediately —
this is an admin action and does not touch `UPGRADER_ROLE`, so it is not timelocked:

```js
const BATCH_COMMITTER_ROLE = await provenance.BATCH_COMMITTER_ROLE();
const OPERATOR_ROLE = await registry.OPERATOR_ROLE();

await provenance.connect(safeSigner).revokeRole(BATCH_COMMITTER_ROLE, oldOperator);
await provenance.connect(safeSigner).grantRole(BATCH_COMMITTER_ROLE, newOperator);

await registry.connect(safeSigner).revokeRole(OPERATOR_ROLE, oldOperator);
await registry.connect(safeSigner).grantRole(OPERATOR_ROLE, newOperator);
```

Pause batch commits first if you suspect the compromised key has already been used maliciously,
then rotate, then unpause once the new key is confirmed safe.
