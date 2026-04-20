# ADR-044: ApplicationSet Matrix Generator for Multi-Cluster Deployment

## Status

Accepted

## Context

Phase 11 deploys the same application suite (backend, frontend, monitoring, security baseline) to three clusters (dev, staging, prod). Manually creating one ArgoCD `Application` per service per cluster would require 12+ Application objects and creates high maintenance overhead.

## Decision

Use ArgoCD `ApplicationSet` with a Matrix generator combining a `list` generator (clusters) and a `git` generator (chart directories). One `ApplicationSet` generates all `Application` objects automatically.

## Alternatives Considered

| Option | Pros | Cons |
|---|---|---|
| ApplicationSet with Matrix generator | One definition generates N×M Applications automatically; changes to the generator propagate to all apps | Matrix generators are more complex to reason about; order of generators matters |
| Individual Application per cluster per chart | Explicit, easy to override per app | N×M Application objects; changes must be applied M times |
| App of Apps pattern | Hierarchical ArgoCD Applications; well-known pattern | Still requires one parent Application per cluster; less dynamic than ApplicationSet |

## Consequences

- Adding a new cluster requires only adding it to the `list` generator — all Applications are created automatically.
- Adding a new chart directory triggers deployment to all clusters — good for platform-wide components; consider separate ApplicationSets for app-specific charts.
- Destination cluster contexts must be registered in ArgoCD (`argocd cluster add`) before the ApplicationSet can deploy to them.
- ArgoCD must have `cluster-admin` on destination clusters (or a scoped role) to create resources across namespaces.
