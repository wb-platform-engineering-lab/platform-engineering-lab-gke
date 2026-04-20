# ADR-035: Default-Deny NetworkPolicy with Explicit Allow Rules

## Status

Accepted

## Context

By default, Kubernetes allows all pod-to-pod communication within a cluster. A compromised pod can reach any other pod, including the database, on any port. Phase 10 introduces NetworkPolicies to enforce micro-segmentation.

## Decision

Apply a default-deny `NetworkPolicy` to the `default` namespace that blocks all ingress and egress. Then add explicit allow rules: frontend → backend on port 8080; backend → PostgreSQL on port 5432; backend → Redis on port 6379.

## Alternatives Considered

| Option | Pros | Cons |
|---|---|---|
| Default-deny + explicit allow | Strong blast radius containment; explicit documentation of allowed traffic paths | Operational overhead: every new service needs a policy; easy to block legitimate traffic by mistake |
| Allow-all (default Kubernetes) | No operational friction | A compromised pod can reach every other pod and database in the cluster |
| Calico GlobalNetworkPolicy | Cluster-wide default-deny without per-namespace policies | Requires Calico CNI; GKE uses different CNI by default |

## Consequences

- GKE must use a network policy-capable CNI (GKE Dataplane V2 or Calico add-on).
- New services must add their NetworkPolicy before they can communicate — "works locally, blocked in cluster" is a common first encounter.
- DNS (port 53 to `kube-dns`) must be explicitly allowed in the egress rule or pods cannot resolve service names.
- NetworkPolicy enforcement is visible via Falco (Phase 10b) — dropped connections generate alerts.
