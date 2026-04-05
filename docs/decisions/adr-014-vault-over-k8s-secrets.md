# ADR-014 — HashiCorp Vault over Kubernetes Secrets or GCP Secret Manager

## Status

Accepted

## Context

CoverLine reached 100,000 members and is closing its first enterprise deal. A security audit revealed that database credentials were stored as plaintext environment variables in Kubernetes manifests committed to Git. A developer accidentally committed a `.env` file, causing a 40-minute outage during emergency credential rotation.

Three options were evaluated for centralised secret management:

| Option | Description |
|---|---|
| **Kubernetes Secrets** | Native K8s resource, base64-encoded, stored in etcd |
| **GCP Secret Manager** | Fully managed GCP service, IAM-controlled |
| **HashiCorp Vault** | Open-source secret management platform, self-hosted |

## Decision

Use **HashiCorp Vault** deployed on GKE.

## Rationale

### Why not Kubernetes Secrets?

Kubernetes Secrets are base64-encoded, not encrypted at rest by default. Anyone with `kubectl get secret` access (or etcd access) can read them in plaintext. They provide no audit log, no dynamic secret generation, and no fine-grained access control beyond RBAC. They are appropriate for low-sensitivity config but not for production database credentials.

### Why not GCP Secret Manager?

GCP Secret Manager is a strong option for GCP-only workloads — fully managed, IAM-integrated, audit-logged via Cloud Audit Logs. However, it creates a hard dependency on GCP. The Phase 11 capstone targets multi-cloud deployment and CKS certification, which requires demonstrating cloud-agnostic security patterns. Secret Manager also lacks dynamic secret generation.

### Why Vault?

- **Dynamic secrets**: Vault can generate short-lived, unique PostgreSQL credentials per pod — a compromised credential expires automatically
- **Kubernetes auth**: Pods authenticate using their native ServiceAccount JWT — no static credentials required
- **Agent injector**: Secrets are mounted as files into the pod filesystem, never as environment variables or in manifests
- **Audit log**: Every read and write is logged with timestamp, client, and path
- **Cloud-agnostic**: Works identically on GCP, AWS, Azure, or on-premises
- **Certification alignment**: Vault knowledge is directly tested in CKS and valued in GCP Professional Cloud DevOps Engineer

## Consequences

- **Operational overhead**: Vault requires initialization, unsealing, and backup. Mitigated in production with GCP KMS auto-unseal and Raft HA.
- **Single point of failure**: If Vault is unavailable, pods that need secrets cannot start. Mitigated with HA mode (Phase 11).
- **Learning curve**: Vault concepts (policies, auth methods, secret engines) require onboarding time.
- **Not fully managed**: Unlike GCP Secret Manager, Vault requires operational investment. Accepted trade-off for portability and dynamic secrets.
