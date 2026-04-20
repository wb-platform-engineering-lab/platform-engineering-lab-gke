# ADR-032: PodDisruptionBudget Using minAvailable over maxUnavailable

## Status

Accepted

## Context

Phase 8 adds PodDisruptionBudgets (PDB) to ensure the CoverLine backend remains available during voluntary disruptions (node drains, upgrades). PDBs can be expressed as `minAvailable` (minimum healthy pods) or `maxUnavailable` (maximum pods that can be down simultaneously).

## Decision

Use `minAvailable: 2` for the backend PDB. This guarantees at least 2 pods are always running during any voluntary disruption.

## Alternatives Considered

| Option | Pros | Cons |
|---|---|---|
| `minAvailable: 2` | Absolute guarantee — always 2 healthy pods regardless of replica count | If total replicas = `minAvailable`, ALLOWED DISRUPTIONS = 0, blocking drains and upgrades |
| `maxUnavailable: 1` | Scales with replica count — 1 pod can always be down | Less intuitive for operators; 1 unavailable out of 2 = 50% degraded |
| `minAvailable: 50%` | Percentage-based, scales automatically | Rounds down for small replica counts; less predictable |

## Consequences

- With `minAvailable: 2` and 2 replicas: `ALLOWED DISRUPTIONS: 0` — node drains are blocked.
- Students must scale to 3 replicas before testing node drain or performing a cluster upgrade (Phase 8, Challenge 6).
- This behaviour is intentional — it teaches the interaction between PDB and operational procedures.
- In production, set `minAvailable` to one less than the desired replica count, or use `maxUnavailable: 1` for rolling-upgrade-friendly behaviour.
