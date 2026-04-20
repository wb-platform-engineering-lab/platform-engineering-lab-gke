# ADR-014: Workload Identity Federation for GitHub Actions

## Status

Accepted

## Context

The CI/CD pipeline (GitHub Actions) needs to push Docker images to GCR and deploy to GKE. This requires GCP credentials. Storing a service account JSON key as a GitHub secret is a common but risky pattern — keys can leak, expire unnoticed, or be over-permissioned.

## Decision

Use GCP Workload Identity Federation to allow GitHub Actions workflows to authenticate to GCP using short-lived OIDC tokens. No service account keys are created or stored.

## Alternatives Considered

| Option | Pros | Cons |
|---|---|---|
| Workload Identity Federation | Keyless, short-lived tokens, auditable, no rotation needed | Requires GCP Workload Identity Pool and Provider setup; more complex initial configuration |
| Service account JSON key as GitHub secret | Simple, widely understood | Key stored in GitHub; must be rotated manually; overly broad if not scoped carefully; leaked keys grant persistent access |

## Consequences

- GitHub Actions workflow uses `google-github-actions/auth` action with `workload_identity_provider` and `service_account` inputs.
- The GCP service account is granted only the minimum roles needed: Artifact Registry Writer and GKE Developer.
- Token audience is bound to the specific GitHub repository — a token stolen from one repo cannot be used by another.
- Developers don't need GCP credentials locally for CI — only for local development via `gcloud auth application-default login`.
