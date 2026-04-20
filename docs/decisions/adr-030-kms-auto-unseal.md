# ADR-030: GCP KMS Auto-Unseal for Vault

## Status

Accepted

## Context

Vault encrypts its storage backend with a master key. On startup, Vault is in a sealed state and cannot serve requests until the master key is provided (unseal). Manual unseal requires a quorum of key holders to be available, which is operationally inconvenient for a lab VM that may restart.

## Decision

Configure Vault to use GCP Cloud KMS for auto-unseal. On startup, Vault calls KMS to decrypt the master key automatically — no human intervention required.

## Alternatives Considered

| Option | Pros | Cons |
|---|---|---|
| GCP KMS auto-unseal | Automatic recovery after restart; no manual intervention; KMS key access is IAM-controlled and audited | KMS availability becomes a dependency for Vault unseal; KMS key must be protected |
| Shamir key shares (manual unseal) | No external dependency; air-gapped environments | Requires humans with key shares to be available for every restart — unworkable for automated environments |
| Vault Enterprise HSM | Hardware-backed, most secure | Enterprise licence required; not available for lab use |

## Consequences

- The Vault VM's service account needs `cloudkms.cryptoKeyVersions.useToDecrypt` IAM permission on the KMS key.
- If the KMS key is deleted or access is revoked, Vault cannot unseal — treat the KMS key as a critical dependency.
- Auto-unseal is configured in `vault.hcl` under the `seal "gcpckms"` stanza.
- KMS operations are logged in Cloud Audit Logs — every Vault unseal event is traceable.
