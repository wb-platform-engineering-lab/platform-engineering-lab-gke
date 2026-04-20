# ADR-025: Loki over Elasticsearch for Log Aggregation

## Status

Accepted

## Context

CoverLine services emit logs to stdout. GKE captures these as node-level log files. A centralised log aggregation system is needed to query logs across pods, namespaces, and time ranges from a single interface.

## Decision

Use Grafana Loki for log aggregation, with Promtail as the log collector DaemonSet. Logs are queried via LogQL in Grafana (already running from ADR-024) — no separate log UI needed.

## Alternatives Considered

| Option | Pros | Cons |
|---|---|---|
| Loki + Promtail | Lightweight, label-indexed (not full-text), integrates with existing Grafana, low memory footprint | Not full-text search — queries are label + regex based; not suitable for complex log analytics |
| Elasticsearch + Kibana (ELK) | Full-text search, rich analytics, mature | Very high memory and storage requirements; separate UI; expensive to operate for a lab |
| GCP Cloud Logging | Fully managed, already collecting logs via GKE | Query UI less developer-friendly; logs leave the cluster; costs scale with volume |

## Consequences

- Loki indexes only labels (namespace, pod, container), not log content — queries use `{namespace="default"} |= "error"` syntax.
- Storage requirement is much lower than Elasticsearch — suitable for the lab's PVC budget.
- Grafana Explore tab provides unified metrics + logs correlation — clicking a spike in a Prometheus graph can open the corresponding Loki logs.
- Promtail DaemonSet must tolerate all node taints to ensure logs are collected from every node.
