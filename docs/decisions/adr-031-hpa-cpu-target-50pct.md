# ADR-031: HPA CPU Target at 50% Utilisation

## Status

Accepted

## Context

Phase 8 configures Horizontal Pod Autoscaler (HPA) for the CoverLine backend. The CPU utilisation target determines when the HPA adds or removes pods. A target that is too high means pods are overloaded before scaling out; too low means unnecessary scaling and cost.

## Decision

Set the HPA CPU target at 50% (`averageUtilization: 50`). This leaves 50% headroom for traffic bursts before the HPA triggers a scale-out, and allows pods to consolidate during low traffic without constant scaling noise.

## Alternatives Considered

| Option | Pros | Cons |
|---|---|---|
| 50% target | Good burst headroom; scales before saturation; industry standard starting point | May over-provision during sustained low traffic |
| 80% target | More cost-efficient at steady state | Only 20% headroom before saturation; scale-out may not complete before user impact |
| 30% target | Maximum headroom | Frequent scale events; under-utilised pods; higher base cost |

## Consequences

- HPA requires metrics-server to be running in the cluster (`kubectl top pods` must work).
- With `minReplicas: 2` and `maxReplicas: 10`, the backend can handle 5× baseline traffic before hitting the ceiling.
- CPU utilisation is measured against `requests.cpu` — requests must be set accurately (see ADR-004 on rightsizing).
- Scale-down has a 5-minute stabilisation window by default — prevents flapping after a brief traffic spike.
