# ADR-002: Spot Nodes for the GKE Node Pool

## Status

Accepted

## Context

GKE node pools can use either standard (on-demand) or spot (preemptible) VM instances. Cost is a key constraint for this lab environment, as the cluster is not running production traffic.

## Decision

Use spot nodes (`spot = true`) for the node pool in dev and staging environments.

## Alternatives Considered

| Option | Pros | Cons |
|---|---|---|
| Spot nodes (chosen) | 60–70% cheaper than on-demand | GCP can reclaim with 30s notice, max lifetime 24h |
| On-demand nodes | Stable, no interruptions | Significantly higher cost for a lab environment |
| Autopilot mode | No node management, pay per pod | Less control, harder to learn node-level concepts |

## Consequences

- Node costs are reduced by ~60–70% compared to standard instances
- Workloads must tolerate interruption — acceptable for a lab, not for stateful production workloads
- In a real production setup, a separate on-demand node pool would be used for critical or stateful workloads
- Autoscaling (`min: 1`, `max: 3`) is enabled to handle spot node reclamation gracefully
