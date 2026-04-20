# ADR-033: Cluster Autoscaler over Fixed Node Count

## Status

Accepted

## Context

The GKE cluster uses Spot nodes (ADR-004) which can be preempted at any time. The HPA (ADR-031) can scale pods beyond what the current nodes can schedule. A mechanism is needed to add nodes when pods are pending and remove nodes when they are underutilised.

## Decision

Enable GKE Cluster Autoscaler on the node pool with `min_node_count = 1` and `max_node_count = 4`. The autoscaler adds nodes when pods are unschedulable and removes nodes after they have been underutilised for 10+ minutes.

## Alternatives Considered

| Option | Pros | Cons |
|---|---|---|
| Cluster Autoscaler | Responds to pending pods; removes idle nodes; built into GKE | Scale-out takes 2–4 minutes (node provisioning time); not suitable for sudden sharp traffic spikes |
| GKE Autopilot | Fully managed node provisioning | Different cluster type; less control for learning; different resource model |
| Fixed node count | Predictable cost | Wastes money during low traffic; fails when traffic spikes exceed capacity |

## Consequences

- HPA and Cluster Autoscaler compose: HPA creates pending pods → Cluster Autoscaler adds nodes → pods schedule.
- Node scale-down requires pods to be reschedulable elsewhere — PDB and `minAvailable` (ADR-032) affect whether a node can be drained.
- Spot node preemption triggers immediate replacement — Cluster Autoscaler detects the NotReady node and provisions a new one.
- `max_node_count: 4` caps runaway scaling — protects against cost surprises from a misconfigured HPA.
