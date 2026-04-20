# ADR-010: Helm over Raw Kubernetes Manifests

## Status

Accepted

## Context

CoverLine deploys to multiple environments (dev, staging, production). The same application needs different resource limits, replica counts, and hostnames per environment. Managing separate copies of raw YAML manifests leads to configuration drift.

## Decision

Package all CoverLine services as Helm charts. Use per-environment `values-*.yaml` files to override defaults. Helm is also used to install third-party software (Prometheus, ArgoCD, Vault, Kubecost).

## Alternatives Considered

| Option | Pros | Cons |
|---|---|---|
| Helm | Templating, versioned releases, `helm diff`, `helm rollback`, widely adopted | Template syntax (Go templates) is verbose; `helm upgrade --atomic` can mask failures |
| Kustomize | Patch-based, no template engine, built into `kubectl` | No release tracking or rollback; harder to reason about final output for complex overlays |
| Raw YAML per environment | Simple to read | Duplication across environments; configuration drift; no versioning |

## Consequences

- Each chart lives in `phase-3-helm/charts/<service>/`.
- `values.yaml` defines defaults; `values-dev.yaml` and `values-prod.yaml` override per environment.
- ArgoCD (Phase 5) deploys by pointing at the Helm chart — GitOps and Helm compose naturally.
- Bitnami charts are used for PostgreSQL and Redis (see ADR-011) rather than writing custom stateful charts.
