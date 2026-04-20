# ADR-015: SHA-Based Image Tagging

## Status

Accepted

## Context

Docker images can be tagged with mutable tags (e.g., `latest`, `main`) or immutable identifiers (git SHA, build number). Mutable tags cause non-deterministic deployments: two deploys of `latest` may use different image contents.

## Decision

Tag every image with the full git commit SHA (`$GITHUB_SHA`). Optionally also tag with `latest` for convenience, but ArgoCD and Helm values always reference the SHA tag.

## Alternatives Considered

| Option | Pros | Cons |
|---|---|---|
| Git SHA tag | Immutable, traceable to exact commit, safe to reference in GitOps | Longer tag string; humans can't tell age at a glance |
| Semantic version tag | Human-readable, meaningful | Requires version management; not automatically available from git without tagging discipline |
| `latest` tag | Simple | Mutable; rolling back means knowing which SHA was "previous latest" — impossible without another mechanism |

## Consequences

- Every CI run produces a uniquely tagged image — no image is ever overwritten.
- GitOps promotion (Phase 5) works by updating the SHA in the Helm values file and committing — ArgoCD detects the change and rolls out.
- Image registry storage grows unbounded — a cleanup policy (e.g., keep last 20 tags) must be applied to Artifact Registry.
- `docker pull` of an old SHA still works as long as the image has not been garbage-collected.
