# ADR-007: PostgreSQL as the Relational Database

## Status

Accepted

## Context

The backend API requires a relational database for persistent storage. A database technology had to be chosen for the microservices architecture.

## Decision

Use PostgreSQL deployed via Helm (Bitnami chart) on Kubernetes.

## Alternatives Considered

| Option | Pros | Cons |
|---|---|---|
| PostgreSQL (chosen) | Open source, feature-rich, widely used, strong Kubernetes support via Bitnami | Requires managing StatefulSet in Kubernetes |
| MySQL | Widely adopted, simple | Fewer advanced features than PostgreSQL, less popular in cloud-native stacks |
| MongoDB | Flexible schema, good for document storage | No relational model, overkill for a demo API |
| Cloud SQL (managed PostgreSQL) | Fully managed, automatic backups, HA | ~$7-50/day cost, no Kubernetes learning opportunity |
| CockroachDB | Distributed, highly available | Complex, overkill for a lab |

## Consequences

- Deployed as a Kubernetes StatefulSet via the Bitnami Helm chart — teaches PVCs, StatefulSets, and headless services
- In production, this would be replaced with Cloud SQL (managed PostgreSQL) to eliminate operational overhead
- The Bitnami chart provides production-grade defaults (resource limits, liveness probes, persistent storage)
- Connection credentials are managed via Kubernetes Secrets, preparing for Vault integration in Phase 3
