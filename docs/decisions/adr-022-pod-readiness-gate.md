# ADR-022: Pod Readiness Gate for Canary Promotion

## Status

Accepted

## Context

During a canary rollout, Argo Rollouts must know whether the canary pods are healthy before promoting traffic. Kubernetes' built-in readiness probes only check if a pod is ready to receive traffic — they don't signal whether the canary's metrics are within acceptable bounds.

## Decision

Use Argo Rollouts' `readinessGate` with an `AnalysisRun` that queries Prometheus for error rate on the canary pods before each step promotion. The rollout pauses at each step until the analysis passes.

## Alternatives Considered

| Option | Pros | Cons |
|---|---|---|
| Readiness gate + AnalysisRun | Promotion is data-driven; automatic rollback if error rate exceeds threshold | Requires Prometheus metrics and correct label selectors |
| Manual promotion only | Simple; operator makes the call | Slow; requires human attention during every deploy; doesn't scale |
| Time-based promotion | Automatic, simple | Promotes regardless of error rate — doesn't detect regressions |

## Consequences

- `AnalysisTemplate` defines the Prometheus query and success/failure thresholds (e.g., error rate < 5%).
- Canary pods must emit metrics with labels that distinguish them from stable pods (Argo Rollouts adds `rollouts-pod-template-hash`).
- Failed analysis automatically triggers rollback to the stable version — zero manual intervention needed.
- Analysis adds 2–5 minutes per step to the deployment window.
