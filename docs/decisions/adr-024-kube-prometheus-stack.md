# ADR-024: kube-prometheus-stack for Observability

## Status

Accepted

## Context

Phase 6 requires a full observability stack: metrics collection, alerting, and dashboards. Prometheus, Alertmanager, and Grafana are the standard components, but installing and wiring them individually is complex.

## Decision

Use the `kube-prometheus-stack` Helm chart (formerly `prometheus-operator`) to install Prometheus, Alertmanager, and Grafana as a single, pre-integrated package with ServiceMonitor CRDs for scrape target management.

## Alternatives Considered

| Option | Pros | Cons |
|---|---|---|
| kube-prometheus-stack | Pre-wired, includes default dashboards and alert rules for cluster health, ServiceMonitor CRD for declarative scrape targets | Large chart; many components; harder to customise individual pieces |
| Prometheus Operator only | More control | Must wire Prometheus → Alertmanager → Grafana manually |
| Datadog / New Relic | SaaS, minimal setup | Cost, data leaves cluster, vendor lock-in |

## Consequences

- Prometheus, Alertmanager, and Grafana run in the `monitoring` namespace.
- `ServiceMonitor` CRDs allow application teams to add scrape targets without editing Prometheus config directly.
- Kubecost (Phase 10e) reuses this Prometheus instance (`prometheus.enabled=false` in Kubecost Helm values).
- Default alert rules cover node pressure, pod crash loops, and PVC capacity — these are active from day one.
- Grafana dashboards are provisioned as ConfigMaps with `grafana_dashboard: "1"` label (used by Phase 11 Capstone).
