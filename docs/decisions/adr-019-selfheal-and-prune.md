# ADR-019: ArgoCD Self-Heal and Auto-Prune Enabled

## Status

Accepted

## Context

ArgoCD can be configured to automatically sync the cluster to match git, or to only sync when manually triggered. Two sub-options — self-healing and auto-pruning — determine how ArgoCD responds to drift and to resources deleted from git.

## Decision

Enable both `selfHeal: true` and `prune: true` on all ArgoCD Applications. Self-heal: if someone manually changes a resource in the cluster, ArgoCD resets it to match git. Prune: if a resource is removed from git, ArgoCD deletes it from the cluster.

## Alternatives Considered

| Option | Pros | Cons |
|---|---|---|
| Self-heal + prune enabled | Strong GitOps contract — git is always the source of truth | Manual `kubectl` changes are silently overwritten (intentional) |
| Manual sync only | Allows ad-hoc cluster changes | Drift accumulates; git and cluster diverge; "works on my cluster" incidents |
| Self-heal without prune | Fixes changes, leaves orphaned resources | Removed deployments linger; resource bloat over time |

## Consequences

- Engineers must use git to make any change to cluster resources — `kubectl edit` changes will be reverted within minutes.
- Orphaned resources from deleted chart components are cleaned up automatically.
- Emergency manual overrides (e.g., during an incident) require temporarily disabling sync or adding a `argocd.argoproj.io/sync-options: Prune=false` annotation.
- Phase 5 lab deliberately demonstrates drift detection: students observe ArgoCD revert a manual `kubectl scale` command.
