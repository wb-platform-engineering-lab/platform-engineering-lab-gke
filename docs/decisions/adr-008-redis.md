# ADR-008: Redis for Caching

## Status

Accepted

## Context

The backend API needs a caching layer to demonstrate stateful workloads and reduce database load. A caching technology had to be chosen.

## Decision

Use Redis deployed via Helm (Bitnami chart) on Kubernetes.

## Alternatives Considered

| Option | Pros | Cons |
|---|---|---|
| Redis (chosen) | Industry standard, supports caching + pub/sub + queues, excellent Kubernetes support | In-memory only (data lost on restart without persistence) |
| Memcached | Simpler, slightly faster for pure caching | No persistence, no pub/sub, less feature-rich |
| Cloud Memorystore (managed Redis) | Fully managed, HA, automatic failover | ~$3-10/day cost, no Kubernetes learning opportunity |
| Dragonfly | Redis-compatible, higher performance | Less mature, smaller ecosystem |

## Consequences

- Deployed as a Kubernetes StatefulSet via the Bitnami Helm chart alongside PostgreSQL
- In production, this would be replaced with Cloud Memorystore (managed Redis) to eliminate operational overhead
- Demonstrates running two stateful workloads (PostgreSQL + Redis) on the same cluster, which is a common real-world pattern
- Redis persistence is disabled in the lab to reduce disk usage — enable AOF or RDB snapshots in production
