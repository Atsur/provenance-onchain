# Security Policy

## Reporting a Vulnerability

If you discover a security vulnerability in this project, **please do not open a public GitHub issue.**

Report it privately via GitHub's Security Advisory feature:

1. Go to the **Security** tab of this repository
2. Click **"Report a vulnerability"**
3. Fill in the details — include the affected contract(s), a description of the issue, and reproduction steps if possible

We will acknowledge your report within **48 hours** and aim to release a fix within **14 days** for critical issues. We will credit responsible disclosers in the release notes unless you request anonymity.

## Scope

In scope:
- `contracts/AtsurActorRegistry.sol`
- `contracts/AtsurProvenance.sol`
- Deployment and upgrade scripts in `scripts/`

Out of scope:
- Off-chain indexing or backend services
- Third-party dependencies (OpenZeppelin contracts — report those upstream)
- Issues requiring a compromised admin multisig key (admin key security is an operational concern)

## Trust Model

### Role architecture — who holds what, and why

| Role | Holder | Why |
|---|---|---|
| `DEFAULT_ADMIN_ROLE` | Gnosis Safe (2-of-3) | Operational control: grants/revokes `OPERATOR_ROLE`, `BATCH_COMMITTER_ROLE`, `PAUSER_ROLE`; can unpause; can rotate the multisig itself. None of this is timelocked — it is day-to-day governance, gated only by the Safe's own signing threshold. |
| `UPGRADER_ROLE` | `TimelockController` | The *only* authority that can call `_authorizeUpgrade` and push a new implementation. Granted to the timelock at `initialize()` time and then made self-administered (see below), so it can never fall back under direct Safe control. |
| `OPERATOR_ROLE` (registry) / `BATCH_COMMITTER_ROLE` (provenance) | Hot wallet | Day-to-day writes (`registerActor`, `anchorBatch`, etc.). Deliberately the lowest-privilege role and the one most likely to be rotated after a compromise. |
| `PAUSER_ROLE` | Operational/emergency wallet | Can halt batch commits instantly. Cannot unpause — only `DEFAULT_ADMIN_ROLE` can, by design (fast to stop, deliberate to resume). |

### The explicit trust assumption

`UPGRADER_ROLE`'s role-admin is set to itself in both contracts' `initialize()`:

```solidity
_setRoleAdmin(UPGRADER_ROLE, UPGRADER_ROLE);
```

**The Gnosis Safe holds `DEFAULT_ADMIN_ROLE` and can perform operational actions without a
timelock delay. However, `UPGRADER_ROLE` is self-administered
(`_setRoleAdmin(UPGRADER_ROLE, UPGRADER_ROLE)`), meaning the Safe cannot grant itself upgrade
authority — any upgrade must originate from the current `UPGRADER_ROLE` holder (the
`TimelockController`), enforcing the 48-hour delay on all contract upgrades even against the
Safe.** Without this, `UPGRADER_ROLE`'s admin would default to `DEFAULT_ADMIN_ROLE` (the
standard OpenZeppelin `AccessControl` behaviour), and the Safe could re-grant itself upgrade
power in a single transaction, making the timelock purely advisory. Self-administration closes
that gap structurally rather than relying on the Safe simply choosing not to do this.

### What the timelock protects against

- **Unilateral upgrades** by a single compromised key — no individual signer, deployer key, or
  even the Safe acting alone (without going through `TimelockController.schedule`/`execute`)
  can push a new implementation.
- **Compromised-operator-key escalation** — if `OPERATOR_ROLE`/`BATCH_COMMITTER_ROLE` is
  compromised, the attacker still cannot reach `UPGRADER_ROLE`; there is no role-admin path
  from operator-level roles to upgrade authority.
- **A rushed or socially-engineered upgrade proposal** — the 48-hour window gives integrators,
  users, and the community time to inspect a scheduled implementation before it executes.

### What the timelock does not protect against

- **A fully coordinated, malicious Safe performing non-upgrade admin actions.** `DEFAULT_ADMIN_ROLE`
  can still grant/revoke `OPERATOR_ROLE`, `BATCH_COMMITTER_ROLE`, and `PAUSER_ROLE`, and can
  unpause the contract, all without delay. Compromise of the Safe's signing threshold is out of
  scope for on-chain security — see "Admin key centralisation" below.
- **A malicious Safe that already controls the `TimelockController`'s proposer/executor set.**
  The timelock's proposers/executors are configured to the Safe (or deployer, pre-multisig) at
  deploy time; if the same signers control both the Safe and the timelock, they can still
  schedule and execute an upgrade — they simply cannot skip the 48-hour wait to do it.

### Admin key centralisation

`DEFAULT_ADMIN_ROLE` is a Gnosis Safe multisig. Compromise of the multisig's signing threshold
is out of scope for on-chain security; it is a key-management and operational concern.

### Emergency pause — why it intentionally bypasses the timelock

`pauseBatchCommits()` requires only `PAUSER_ROLE` and takes effect immediately, with no
timelock delay. This is deliberate: a pause is a *defensive* action that freezes new writes — it
cannot install new code, change roles, or move funds, so it carries none of the risk an upgrade
does. Gating it behind a 48-hour delay would make the emergency brake useless in an actual
emergency. `unpauseBatchCommits()` requires `DEFAULT_ADMIN_ROLE` (the Safe) — fast to stop,
deliberate to resume.

### Other documented trust assumptions

**Wallet linking without consent (SEV-007)** — `linkSelfCustodialWallet` is callable by the Atsur operator (`OPERATOR_ROLE`) without an ECDSA signature from the linked wallet. This is a documented trust assumption; ECDSA-based wallet consent is planned for a future upgrade. Do not treat this as a vulnerability.

**Permanent verifier revocation override** — `clearVerifierRevocation` is callable by `DEFAULT_ADMIN_ROLE` only and is intended as an admin escape hatch in cases of erroneous revocation. Its use should be accompanied by off-chain governance documentation.

## Supported Versions

| Contract            | Status    |
|---------------------|-----------|
| AtsurActorRegistry  | Active    |
| AtsurProvenance     | Active    |

Older proxy implementations (pre-upgrade) are no longer supported once an upgrade is executed.
