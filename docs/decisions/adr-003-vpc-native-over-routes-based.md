# ADR-003: VPC-Native Networking over Routes-Based Networking

## Status

Accepted

## Context

GKE clusters can be created in either VPC-native mode (alias IPs) or routes-based mode. The networking model affects pod IP allocation, inter-pod routing, and compatibility with GCP services like Cloud NAT and Private Service Connect.

## Decision

Use VPC-native (alias IP) networking for all GKE clusters. Set `ip_allocation_policy` in Terraform to enable alias IPs with explicit pod and service CIDR ranges.

## Alternatives Considered

| Option | Pros | Cons |
|---|---|---|
| VPC-native (alias IPs) | Pods are first-class GCP VPC citizens, no custom routes quota limit, required for Private GKE, works with Cloud NAT | Requires planning IP ranges upfront |
| Routes-based | Simpler setup | Limited to 250 routes per VPC, not compatible with Private GKE clusters, not recommended by GCP |

## Consequences

- Pod and service CIDR ranges must be sized to accommodate cluster growth (too small = nodes can't schedule pods).
- Multiple clusters in the same VPC require non-overlapping secondary ranges (enforced in Phase 11 multi-env setup).
- Pods get routable IPs within the VPC — simplifies debugging but means pod IPs are visible to on-prem connected networks.
