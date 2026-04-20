# ADR-040: Kubecost Free Tier over OpenCost

## Status

Accepted

## Context

Phase 10e requires cost allocation at the namespace, deployment, and label level within the GKE cluster. OpenCost (CNCF sandbox) and Kubecost are both built on the same allocation model — Kubecost originated the OpenCost specification.

## Decision

Use Kubecost free tier (`kubecost/cost-analyzer` Helm chart) for the lab. It provides a built-in UI, rightsizing recommendations, and GCP pricing integration out of the box without additional configuration.

## Alternatives Considered

| Option | Pros | Cons |
|---|---|---|
| Kubecost free tier | UI included, rightsizing view, GCP Pricing API integration, widely documented | Free tier limits: 15-day retention, single cluster, no SAML SSO, no multi-cluster aggregation |
| OpenCost | CNCF project, fully open-source, no tier limits, Prometheus-native | No built-in UI (requires Grafana dashboards); less documentation; newer project |
| GCP Billing export only | No additional tooling | No real-time view; 24-hour delay; no per-deployment breakdown |

## Consequences

- Kubecost reuses the existing `kube-prometheus-stack` Prometheus (`prometheus.enabled=false`) — no additional scrape layer.
- Free tier is sufficient for a single-cluster lab — production multi-cluster environments should evaluate OpenCost or Kubecost Enterprise.
- Rightsizing recommendations require at least 24–48 hours of Prometheus metrics history to produce accurate suggestions.
- Cost data refreshes every 15 minutes — not real-time, but sufficient for FinOps reporting cycles.
