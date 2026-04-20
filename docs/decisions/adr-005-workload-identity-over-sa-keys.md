# ADR-005: Workload Identity over Service Account Keys

## Status

Accepted

## Context

GKE workloads that call GCP APIs (BigQuery, GCS, Pub/Sub) need credentials. The traditional approach exports a JSON service account key and mounts it as a Kubernetes Secret. Workload Identity provides GCP identity to pods without any key material.

## Decision

Enable GKE Workload Identity on the cluster and map Kubernetes ServiceAccounts to GCP Service Accounts using IAM bindings. No JSON keys are created or stored.

## Alternatives Considered

| Option | Pros | Cons |
|---|---|---|
| Workload Identity | No key rotation, no key leakage risk, auditable via Cloud Audit Logs, GKE-native | Requires IAM binding per KSA→GSA pair; adds setup complexity |
| JSON service account key | Simple to understand, works anywhere | Key must be stored as a Secret (base64 encoded), rotated manually, leaked keys are catastrophic |

## Consequences

- Each namespace that needs GCP access requires a KSA → GSA binding (`iam.workloadIdentityUser` role).
- Pods must use the annotated ServiceAccount (`iam.gke.io/gcp-service-account` annotation).
- Service account keys are explicitly prohibited — any key found in a Secret should be treated as a security incident.
- CI pipelines use Workload Identity Federation (see ADR-014) — same principle, different mechanism for GitHub Actions.
