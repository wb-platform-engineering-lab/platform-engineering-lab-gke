# ADR-036: Pod Security Standards (Restricted Profile) over PSP

## Status

Accepted

## Context

Kubernetes deprecated and removed PodSecurityPolicy (PSP) in v1.25. A replacement mechanism is needed to prevent pods from running as root, mounting host paths, or using privileged escalation. Kubernetes introduced Pod Security Admission (PSA) with three profiles: privileged, baseline, and restricted.

## Decision

Apply the `restricted` Pod Security Standard to the `default` namespace via a namespace label. This enforces: non-root user, no privilege escalation, dropped capabilities, seccomp `RuntimeDefault`, and no host path volumes.

## Alternatives Considered

| Option | Pros | Cons |
|---|---|---|
| Pod Security Admission (restricted) | Built-in to Kubernetes 1.25+; no controller needed; easy to audit via namespace labels | Namespace-granular only; no per-deployment exceptions without namespace changes |
| Kyverno ClusterPolicy | More flexible (can target specific labels/annotations); detailed violation reports via PolicyReport | Additional controller to operate (covered in Phase 10b) |
| OPA Gatekeeper | Powerful, extensible | Rego policy language steep learning curve; replaced by Kyverno in this lab (see ADR-018-kyverno-over-gatekeeper) |

## Consequences

- The `default` namespace gets label `pod-security.kubernetes.io/enforce: restricted`.
- Pods that don't comply (e.g., running as root, using `hostPath`) are rejected at admission — workloads must be updated before this label is applied.
- The `monitoring` namespace uses `baseline` to allow Prometheus node-exporter and Promtail to run with required host access.
- Kyverno (Phase 10b) adds finer-grained controls on top of PSA.
