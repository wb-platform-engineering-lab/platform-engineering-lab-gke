# ADR-018: ArgoCD over FluxCD for GitOps

## Status

Accepted

## Context

Phase 6 introduces GitOps: the cluster state is declared in git and a controller reconciles the live state to match. ArgoCD and FluxCD are the two dominant CNCF-graduated GitOps controllers for Kubernetes.

## Decision

Use ArgoCD as the GitOps controller. Deploy it in the `argocd` namespace via its official install manifest. Manage Applications using `Application` and `ApplicationSet` CRDs.

## Alternatives Considered

| Option | Pros | Cons |
|---|---|---|
| ArgoCD | Web UI, RBAC, multi-cluster, ApplicationSet for templating, strong community | Heavier resource footprint than Flux; UI is an additional attack surface |
| FluxCD | Lighter weight, Helm Controller composable with Kustomize Controller, no UI required | No built-in UI (Weave Gitops is separate); steeper learning curve for multi-cluster |

## Consequences

- ArgoCD UI is accessible via `kubectl port-forward` and serves as the live deployment dashboard.
- `Application` sync status is the source of truth for whether a cluster is up-to-date with git.
- `self-healing` and `auto-prune` are enabled (see ADR-019) — manual `kubectl apply` changes are overwritten.
- Phase 11 Capstone uses `ApplicationSet` with a Matrix generator to deploy to 3 clusters from one definition.
