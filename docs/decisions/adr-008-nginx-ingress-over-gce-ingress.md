# ADR-008: NGINX Ingress Controller over GCE Ingress

## Status

Accepted

## Context

GKE offers two Ingress options: the GKE-native GCE Ingress (backed by a GCP Application Load Balancer) and the open-source NGINX Ingress Controller. Both handle HTTP routing, but they differ in cost, configurability, and portability.

## Decision

Install the NGINX Ingress Controller (via Helm) rather than using the GKE-native GCE Ingress class.

## Alternatives Considered

| Option | Pros | Cons |
|---|---|---|
| NGINX Ingress Controller | Portable, rich annotation set, supports canary by header/weight, low cost (one L4 LB) | Must manage controller lifecycle; not managed by GKE |
| GCE Ingress (GKE-native) | Fully managed, integrates with GCP Certificate Manager and Cloud Armor | One GCP Application Load Balancer per Ingress resource = expensive at scale; slower provisioning (3–10 min) |

## Consequences

- NGINX controller runs as a Deployment in the `ingress-nginx` namespace — needs resource requests set.
- One GCP L4 load balancer is created for the NGINX controller's `LoadBalancer` Service — shared across all Ingress resources.
- Canary deployments in Phase 6b use NGINX canary annotations (`nginx.ingress.kubernetes.io/canary-weight`).
- Migrating to GCE Ingress later would require re-annotating all Ingress resources and recreating routing rules.
