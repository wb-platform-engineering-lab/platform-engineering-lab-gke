# ADR-003: VPC-Native Cluster over Routes-Based

## Status

Accepted

## Context

GKE supports two networking modes: routes-based and VPC-native (alias IPs). The choice affects how pod IPs are assigned and how traffic is routed within the cluster.

## Decision

Use VPC-native networking with secondary IP ranges for pods and services.

## Alternatives Considered

| Option | Pros | Cons |
|---|---|---|
| VPC-native / alias IPs (chosen) | Native GCP routing, no custom routes, supports larger clusters, required for some GKE features | Requires pre-planning of CIDR ranges |
| Routes-based | Simpler initial setup | Limited to 250 nodes per cluster (GCP routes quota), no support for Network Policy with Dataplane V2, deprecated path |

## Consequences

- Pod IPs are routable directly within the VPC — no NAT between pods across nodes
- Secondary ranges are pre-allocated: `10.1.0.0/16` for pods (65,536 IPs), `10.2.0.0/20` for services (4,096 IPs)
- Required for enabling GKE Dataplane V2 (eBPF-based networking) in later phases
- CIDR ranges must be planned upfront — overlapping ranges will cause provisioning failures
- This is the Google-recommended and default mode for all new GKE clusters
