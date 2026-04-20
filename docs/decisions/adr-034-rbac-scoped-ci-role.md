# ADR-034: Scoped CI Service Account Role over cluster-admin

## Status

Accepted

## Context

Phase 10 (Security Hardening) audits the permissions of the CI service account used by GitHub Actions to deploy to GKE. A common default is to bind the CI account to `cluster-admin` for convenience — this is a critical security misconfiguration.

## Decision

Bind the CI service account to a custom `ClusterRole` that grants only the permissions needed for deployment: `get`, `list`, `patch`, `update` on `deployments`, `services`, and `configmaps`. Explicitly deny `secrets` access and all cluster-scope write operations.

## Alternatives Considered

| Option | Pros | Cons |
|---|---|---|
| Scoped custom ClusterRole | Least privilege; compromise of CI token limited in blast radius | Must be updated if CI needs new resource types |
| `cluster-admin` | Simple, no permission errors | Full cluster compromise if CI token is stolen; can modify RBAC itself |
| `edit` ClusterRole | Built-in, broad but not cluster-admin | Can read Secrets — CI should not be able to read Secret values |

## Consequences

- CI pipeline fails with `forbidden` errors if a new manifest type is added without updating the ClusterRole — intentional friction.
- The ClusterRole is defined in version control and deployed by Terraform (or ArgoCD bootstrap) — not created manually.
- Secrets are explicitly excluded — CI deploys Helm values referencing Vault paths, not Secret values directly.
- Audit logging (Phase 10b) makes it easy to verify what the CI account actually touches during a deploy.
