# ADR-018b: Kyverno over OPA Gatekeeper for Admission Control

## Status

Accepted (supersedes any prior consideration of OPA Gatekeeper for Phase 10b)

## Context

Phase 10b requires admission control policies to enforce security constraints: pods must not run as root, must not mount `hostPath` volumes, and must have resource limits set. Both Kyverno and OPA Gatekeeper are CNCF-graduated admission controllers for Kubernetes.

## Decision

Use Kyverno for all admission control policies in Phase 10b. Policies are written as Kubernetes YAML (`ClusterPolicy` CRDs) using the same kubectl/GitOps workflow as all other manifests.

## Alternatives Considered

| Option | Pros | Cons |
|---|---|---|
| Kyverno | YAML-native policies (no new language), `PolicyReport` CRD for violation visibility, `generate` and `mutate` capabilities beyond just validation, easier to learn | Fewer pre-built policy libraries than Gatekeeper; JMESPath for complex conditions has a learning curve |
| OPA Gatekeeper | Flexible Rego policies, large policy library (policies.gatekeeper.sh) | Rego is a non-standard policy language — steep learning curve; `ConstraintTemplate` + `Constraint` two-resource model is verbose |

## Consequences

- Policies are `ClusterPolicy` objects stored in `phase-10b-cks/kyverno/` and managed by ArgoCD.
- `validationFailureAction: Enforce` blocks non-compliant pods at admission; `Audit` mode generates `PolicyReport` violations without blocking.
- Background scanning (`background: true`) produces `PolicyReport` objects showing existing violations — existing non-compliant workloads are visible before enforcement is turned on.
- JMESPath expressions in `deny` conditions handle complex array checks (e.g., checking `spec.volumes[?hostPath]`).
- Pod Security Admission (ADR-036) and Kyverno policies are complementary — PSA handles baseline profile enforcement; Kyverno adds fine-grained, label-aware rules.
