# ADR-021: Canary Releases over Blue-Green Deployments

## Status

Accepted

## Context

Phase 6b introduces progressive delivery: rolling out a new version to a subset of users before full promotion. Two dominant patterns exist — blue-green (two full environments, instant switch) and canary (gradual traffic shift by percentage).

## Decision

Implement canary releases using Argo Rollouts with a `Rollout` resource replacing the standard `Deployment`. Traffic is shifted in steps (10% → 40% → 100%) using NGINX Ingress canary annotations.

## Alternatives Considered

| Option | Pros | Cons |
|---|---|---|
| Canary (Argo Rollouts) | Gradual risk, real user traffic on new version at low percentage, automated analysis gates | More complex than blue-green; requires Argo Rollouts controller |
| Blue-green | Instant rollback, no mixed traffic | Doubles infrastructure cost during deployment window; abrupt cutover |
| Standard rolling update | Built-in, no extra controller | No traffic splitting; all-or-nothing at each replica; no automated analysis |

## Consequences

- Argo Rollouts controller runs in `argo-rollouts` namespace.
- `Rollout` objects are not standard Kubernetes — they require the Argo Rollouts `kubectl` plugin for `kubectl argo rollouts` commands.
- NGINX Ingress is required for weight-based traffic splitting via `nginx.ingress.kubernetes.io/canary-weight` (ties to ADR-008).
- Automated analysis (checking error rate metrics from Prometheus before promoting) is configured via `AnalysisTemplate`.
