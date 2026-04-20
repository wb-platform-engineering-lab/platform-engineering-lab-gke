# ADR-016: SonarCloud over Self-Hosted SonarQube

## Status

Accepted

## Context

CoverLine's CI pipeline needs static code analysis to catch bugs, code smells, and security hotspots before merge. SonarQube is the industry standard but requires a self-hosted server. SonarCloud is the SaaS equivalent.

## Decision

Use SonarCloud (SaaS) for static analysis in the GitHub Actions pipeline. It integrates directly with GitHub pull requests and requires no infrastructure to operate.

## Alternatives Considered

| Option | Pros | Cons |
|---|---|---|
| SonarCloud | Free for public repos, GitHub PR decoration, no server needed | Data leaves the environment; not suitable for regulated codebases |
| SonarQube (self-hosted) | Full control, on-premises, enterprise features | Requires a VM or Kubernetes deployment; maintenance overhead; licence cost for developer edition |

## Consequences

- Analysis results appear as GitHub PR comments and block merge if quality gate fails.
- `SONAR_TOKEN` stored as a GitHub Actions secret (not a GCP secret — it's a SaaS credential).
- Public lab repository qualifies for SonarCloud free tier — no cost.
- If CoverLine moves to a private codebase, the free tier limit (public repos only) would require a paid plan.
