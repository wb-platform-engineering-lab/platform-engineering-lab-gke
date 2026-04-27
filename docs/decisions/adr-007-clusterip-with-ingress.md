# ADR-007: ClusterIP Services with Ingress for External Access

## Status

Accepted

## Context

CoverLine services need to be accessible externally (frontend) and internally (backend API). Kubernetes offers ClusterIP, NodePort, LoadBalancer, and Ingress options. Each has different cost and operational implications on GKE.

## Decision

Use `ClusterIP` for all internal service-to-service communication. Use a single NGINX Ingress controller with `Ingress` resources to route external HTTP/S traffic to the appropriate ClusterIP services.

## Alternatives Considered

| Option | Pros | Cons |
|---|---|---|
| ClusterIP + Ingress | One cloud load balancer for all services, path-based routing, TLS termination at one point | Requires Ingress controller installation |
| LoadBalancer per service | Simple, no Ingress controller | One GCP L4 load balancer per service = significant cost at scale |
| NodePort | No load balancer needed | Exposes high-numbered ports, requires external load balancer anyway for production |

## Consequences

- A single GCP load balancer fronts the NGINX Ingress controller — cost-efficient.
- All external routing rules are managed as `Ingress` YAML manifests in version control.
- TLS certificates can be managed per-`Ingress` via cert-manager (Phase 3 builds on this).
- Backend services are not directly reachable from outside the cluster — only via Ingress paths.
