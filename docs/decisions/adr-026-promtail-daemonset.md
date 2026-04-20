# ADR-026: Promtail DaemonSet for Log Collection

## Status

Accepted

## Context

Logs from Kubernetes pods are written to node-level log files under `/var/log/pods/`. A log collector must run on every node to tail these files and forward them to Loki. The collector can run as a DaemonSet (one pod per node) or as a sidecar (one container per application pod).

## Decision

Deploy Promtail as a DaemonSet in the `monitoring` namespace. Promtail reads pod logs from the node filesystem and forwards them to Loki, enriching each log line with Kubernetes metadata (namespace, pod name, container name, labels).

## Alternatives Considered

| Option | Pros | Cons |
|---|---|---|
| Promtail DaemonSet | One installation, no application changes required, enriches with k8s metadata automatically | Runs on every node — resource usage scales with node count |
| Sidecar log collector | Per-pod control, can forward to different destinations | Requires modifying every Deployment; resource duplication |
| Fluent Bit DaemonSet | More powerful routing (multiple outputs), lower memory than Fluentd | More configuration complexity; Promtail is simpler for Loki-only forwarding |

## Consequences

- Promtail must be granted read access to `/var/log/pods` and `/var/log/containers` on the node — requires `hostPath` volume mounts.
- Pod logs are available in Grafana Loki within seconds of emission.
- Promtail uses Kubernetes API to enrich logs with labels — it needs a ClusterRole with `pods` and `namespaces` read access.
- Log retention in Loki is controlled by the `retention_period` config — set to 7 days for the lab to limit PVC usage.
