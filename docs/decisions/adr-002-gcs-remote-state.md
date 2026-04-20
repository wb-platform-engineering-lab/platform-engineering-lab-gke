# ADR-002: GCS Remote State with Versioning

## Status

Accepted

## Context

Terraform state must be stored outside developer machines so that CI pipelines and multiple engineers share the same view of infrastructure. State also needs locking to prevent concurrent `apply` runs from corrupting it.

## Decision

Store Terraform state in a GCS bucket with versioning enabled. Use GCS object locking as the state lock backend (native to the `google` Terraform backend).

## Alternatives Considered

| Option | Pros | Cons |
|---|---|---|
| GCS backend | Native GCP, no extra service, free tier covers lab usage, versioning provides rollback | Locking requires GCS bucket-level config; no UI |
| Terraform Cloud | Built-in UI, run history, RBAC | Requires account, costs money at team scale, adds external dependency |
| Local state | Zero setup | Breaks in CI, no team sharing, no locking, state loss risk |

## Consequences

- State bucket must be created manually before `terraform init` (chicken-and-egg: Terraform can't create its own backend).
- Versioning allows rollback if state is accidentally corrupted.
- All CI pipelines authenticate via Workload Identity Federation (see ADR-005) to access the state bucket.
- State contains sensitive values (database passwords, service account keys) — bucket must not be public.
