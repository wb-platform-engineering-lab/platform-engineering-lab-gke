# ADR-006: Deployment over Bare Pods

## Status

Accepted

## Context

Kubernetes workloads can be expressed as bare Pods, ReplicaSets, Deployments, StatefulSets, or DaemonSets. The CoverLine backend and frontend services are stateless HTTP services that need multiple replicas and rolling update capability.

## Decision

Use `Deployment` objects for all stateless CoverLine services (backend, frontend). Use `StatefulSet` only for services with stable network identity or persistent storage requirements (PostgreSQL, Redis).

## Alternatives Considered

| Option | Pros | Cons |
|---|---|---|
| Deployment | Self-healing, rolling updates, rollback, scales horizontally | Pods share no stable identity — not suitable for databases |
| Bare Pod | Simple YAML | No rescheduling on failure, no rolling update, no scaling |
| ReplicaSet | Maintains replica count | No rolling update strategy — Deployment wraps ReplicaSet and adds this |

## Consequences

- Deployments provide `kubectl rollout undo` rollback capability used throughout the lab.
- `maxUnavailable` and `maxSurge` rolling update parameters are tunable per Deployment.
- StatefulSets (PostgreSQL, Redis) require PVCs and headless Services for stable DNS names.
