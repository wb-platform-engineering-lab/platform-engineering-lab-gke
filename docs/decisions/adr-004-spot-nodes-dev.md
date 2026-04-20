# ADR-004: Spot Nodes for Development Environment

## Status

Accepted

## Context

GKE node pools can use on-demand or Spot (preemptible) VM instances. Spot instances are available at up to 80% discount but can be reclaimed by GCP with 30 seconds notice. The dev environment runs non-production workloads used only during lab exercises.

## Decision

Use Spot instances (`spot = true` in Terraform) for the dev GKE node pool. Use on-demand instances for any production-grade workloads.

## Alternatives Considered

| Option | Pros | Cons |
|---|---|---|
| Spot nodes | 60–80% cost reduction, appropriate for lab workloads | Can be preempted at any time; pods may be evicted mid-exercise |
| On-demand nodes | Stable, no preemption | 3–5× more expensive for equivalent compute |

## Consequences

- Spot preemption causes pods to be rescheduled — students encounter this and learn about PodDisruptionBudgets.
- Not suitable for stateful workloads without PVCs and PDB configuration.
- Cluster Autoscaler handles replacement when Spot nodes are reclaimed (works with Phase 8 autoscaling).
- Dev environment cost stays within the lab budget (~$0.66/day for a 2-node e2-medium cluster).
