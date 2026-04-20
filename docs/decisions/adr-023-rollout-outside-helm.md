# ADR-023: Argo Rollout Resource Managed Outside Helm Chart

## Status

Accepted

## Context

The CoverLine backend is deployed via Helm chart (Phase 3). Adding Argo Rollouts support means replacing the `Deployment` with a `Rollout` resource. This change can be done inside the Helm chart or as a separate manifest managed directly by ArgoCD.

## Decision

Manage the `Rollout` resource as a standalone YAML manifest in `phase-5b-canary/` rather than modifying the Phase 3 Helm chart. The Helm chart's `Deployment` is disabled via `replicaCount: 0` while the Rollout is active.

## Alternatives Considered

| Option | Pros | Cons |
|---|---|---|
| Rollout outside Helm | Phase 3 chart unchanged; canary config isolated in its own phase directory; easier to remove | Two sources of truth for the same service; requires disabling the Helm Deployment |
| Rollout inside Helm chart | Single source of truth | Requires modifying Phase 3 chart; canary config mixed with application config; harder to teach the concept in isolation |

## Consequences

- Students can compare the `Deployment` (Phase 3) and `Rollout` (Phase 5b) YAML side-by-side — the structural similarity is the learning point.
- In production, the `Rollout` should replace the `Deployment` within the Helm chart using a conditional template (`{{- if .Values.canary.enabled }}`).
- ArgoCD manages both the Helm Application and the standalone Rollout manifest — sync order matters (Rollout depends on the Service from the chart).
