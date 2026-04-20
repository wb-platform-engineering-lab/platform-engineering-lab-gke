# ADR-011: Bitnami Charts for Stateful Services (PostgreSQL, Redis)

## Status

Accepted

## Context

CoverLine requires PostgreSQL for persistent data and Redis for session caching. Writing production-quality StatefulSet manifests for these services from scratch is complex and error-prone (init containers, PVC management, password handling, readiness probes).

## Decision

Use the Bitnami Helm charts for `postgresql` and `redis`. Pin chart versions in `Chart.yaml` dependencies and override values via `values.yaml`.

## Alternatives Considered

| Option | Pros | Cons |
|---|---|---|
| Bitnami charts | Battle-tested, well-maintained, sensible defaults, covers auth, PVC, replication | Chart API changes between major versions require migration |
| Cloud SQL / Memorystore | Fully managed, no ops burden | Not free tier, adds GCP dependency, diverges from portable Kubernetes learning |
| Custom StatefulSet | Full control | Complex to write correctly (volume claim templates, headless service, init containers) |

## Consequences

- PostgreSQL and Redis run in-cluster — suitable for lab and dev; production should evaluate Cloud SQL and Memorystore.
- Chart versions are pinned to prevent unplanned upgrades during the lab.
- Passwords are stored in Kubernetes Secrets created by the chart — later replaced by Vault dynamic credentials (Phase 7).
- PVC sizes are set small (1Gi) for the lab; production would need larger PVCs and a storage class with expansion enabled.
