# ADR-041: Three-Label Attribution Strategy (team / env / product)

## Status

Accepted

## Context

Kubecost allocates cost based on Kubernetes labels. Without labels, all cost shows as "unallocated" at the namespace level. The label strategy determines the granularity of cost reporting and must align with how the business wants to view spending.

## Decision

Apply three standard labels to all workload pods: `team` (engineering team owner), `env` (environment: production, staging, dev), and `product` (business product or feature). These are applied as pod template labels in all Deployments and StatefulSets.

## Alternatives Considered

| Option | Pros | Cons |
|---|---|---|
| team + env + product (3 labels) | Answers "which team, in which environment, for which product" — the three questions finance and engineering both ask | Three labels to maintain; all workloads must be labelled consistently |
| Namespace-only attribution | No labelling required; namespace is already present | Multiple teams sharing a namespace produces a single allocation line — cannot split by team or product |
| Cost centre code label | Direct mapping to finance GL codes | Engineers don't know GL codes; adds finance process dependency to every deployment |

## Consequences

- `team` enables showback reporting per engineering team (sent to Slack weekly).
- `env` allows separate dev vs production cost tracking — dev waste is visible without polluting production cost data.
- `product` answers the CFO's question: which business feature costs how much.
- Kubecost only picks up labels on the pod template (`spec.template.metadata.labels`), not the Deployment metadata — this is a common mistake when patching.
- Custom labels (`team`, `product`) only appear in BigQuery billing export if GKE resource usage metering is enabled in Terraform (`resource_usage_export_config`).
