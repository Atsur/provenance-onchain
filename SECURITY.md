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

## Known Trust Assumptions

The following design decisions are intentional and acknowledged:

**Admin key centralisation** — `DEFAULT_ADMIN_ROLE` is a Gnosis Safe multisig. Compromise of the multisig is out of scope for on-chain security; it is a key-management and operational concern.

**Upgrade delay** — Contract upgrades are gated by `UPGRADER_ROLE`, which should be held by a `TimelockController` (see `scripts/setupTimelock.js`). The timelock delay provides a window for users to observe and react to proposed upgrades before they execute.

**Wallet linking without consent (SEV-007)** — `linkSelfCustodialWallet` is callable by the Atsur operator (`OPERATOR_ROLE`) without an ECDSA signature from the linked wallet. This is a documented trust assumption; ECDSA-based wallet consent is planned for a future upgrade. Do not treat this as a vulnerability.

**Permanent verifier revocation override** — `clearVerifierRevocation` is callable by `DEFAULT_ADMIN_ROLE` only and is intended as an admin escape hatch in cases of erroneous revocation. Its use should be accompanied by off-chain governance documentation.

## Supported Versions

| Contract            | Status    |
|---------------------|-----------|
| AtsurActorRegistry  | Active    |
| AtsurProvenance     | Active    |

Older proxy implementations (pre-upgrade) are no longer supported once an upgrade is executed.
