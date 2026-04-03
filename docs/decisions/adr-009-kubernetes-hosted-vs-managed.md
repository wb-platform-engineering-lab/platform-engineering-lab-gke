# ADR-009: Kubernetes-Hosted Databases vs Managed GCP Services

## Status

Accepted

## Context

PostgreSQL and Redis can be deployed either as Kubernetes workloads (Helm charts) or as managed GCP services (Cloud SQL and Cloud Memorystore). A decision was needed on which approach to use in this lab.

## Decision

Use Kubernetes-hosted PostgreSQL and Redis (Bitnami Helm charts) for this lab, with a clear note that Cloud SQL and Memorystore are the production equivalents.

## Alternatives Considered

| Option | Pros | Cons |
|---|---|---|
| Kubernetes-hosted via Helm (chosen) | Free (uses existing nodes), teaches StatefulSets and PVCs, real-world Kubernetes skills | Operational overhead, not suitable for critical production data |
| Cloud SQL + Memorystore | Fully managed, HA, automatic backups, production-grade | ~$10-60/day extra cost, no Kubernetes StatefulSet learning |

## Consequences

- Cost is kept to a minimum — no additional GCP services beyond the GKE cluster
- StatefulSets, PersistentVolumeClaims, and headless services are practiced hands-on
- The architecture explicitly documents the production equivalent, so the portfolio demonstrates awareness of both approaches
- This is a deliberate lab trade-off — the decision would be reversed for any real production workload handling user data
