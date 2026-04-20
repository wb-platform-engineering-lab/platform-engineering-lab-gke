# ADR-046: GitHub Environments for Promotion Approval Gates

## Status

Accepted

## Context

Phase 11 requires a promotion pipeline: dev → staging → prod with manual approval before each production deployment. The approval mechanism must be auditable (who approved, when) and must block automated promotion without explicit sign-off.

## Decision

Use GitHub Environments (`staging` and `production`) with required reviewers configured on each environment. The GitHub Actions promotion workflow pauses and waits for a named reviewer to approve before proceeding to the next environment.

## Alternatives Considered

| Option | Pros | Cons |
|---|---|---|
| GitHub Environments + required reviewers | Native to GitHub, approval logged in the Actions run, no additional tooling | Reviewer must have repo access; environment protection rules require GitHub Team or Enterprise for private repos |
| ArgoCD sync window | ArgoCD-native, can restrict by time window | Time-based, not person-based approval; ArgoCD must be accessible to approver |
| Manual PR per environment | Full review of changes before each promotion | Slow; creates many short-lived branches; review content is the diff, not the deployment decision |

## Consequences

- Production deployments require explicit approval from a named engineer in the `production` GitHub Environment.
- Approval event is logged in GitHub Actions history — provides an audit trail for change management.
- Rejected promotions halt the workflow without deploying — the engineer must re-trigger after addressing the concern.
- GitHub Environment secrets (per-environment kubeconfig or credentials) are only injected into the workflow when that environment's job runs — dev credentials never touch the prod job.
