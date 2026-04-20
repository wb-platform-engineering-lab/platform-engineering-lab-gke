# ADR-001: Terraform over GCP Deployment Manager

## Status

Accepted

## Context

CoverLine's GKE cluster, VPC, and supporting infrastructure need to be provisioned repeatably across dev and production environments. GCP offers its own Deployment Manager, but the team evaluated both options before committing to an IaC tool.

## Decision

Use Terraform (HashiCorp) with the `google` and `google-beta` providers to manage all GCP infrastructure.

## Alternatives Considered

| Option | Pros | Cons |
|---|---|---|
| Terraform | Multi-cloud, large ecosystem, strong GKE module support, team familiarity | Requires remote state management; Terraform Cloud or GCS bucket needed |
| GCP Deployment Manager | Native GCP, no state file management | YAML/Jinja only, poor module ecosystem, GCP-only — not portable if infra expands |

## Consequences

- Remote state must be stored in GCS with locking (see ADR-002).
- All engineers need Terraform installed locally or in CI.
- GCP-specific resources (e.g., GKE Autopilot) use `google-beta` provider and may require version pinning.
- Infrastructure changes go through `terraform plan` review before apply — safe for production.
