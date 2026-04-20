# ADR-037: Trivy --ignore-unfixed Flag in Security Scanning

## Status

Accepted

## Context

Trivy image scanning (ADR-017) reports CVEs including those for which no patched version exists in the upstream package registry. These unfixable CVEs cannot be remediated by updating the image — they create permanent pipeline noise and block deployments for issues the team cannot act on.

## Decision

Run Trivy with `--ignore-unfixed` to suppress CVEs where no fix is available. The pipeline fails only on HIGH and CRITICAL severity CVEs that have a patched version the team can actually upgrade to.

## Alternatives Considered

| Option | Pros | Cons |
|---|---|---|
| `--ignore-unfixed` | Actionable results only; no false-positive blocks | Unfixed CVEs are silently skipped — risk acceptance without explicit tracking |
| Report all CVEs, fail on any HIGH/CRITICAL | Maximum visibility | Permanent pipeline failures on unfixable CVEs; team learns to ignore all scan results |
| Trivy `.trivyignore` allowlist | Explicit risk acceptance per CVE | Manual maintenance overhead; easy to blanket-ignore real issues |

## Consequences

- Unfixable CVEs are still visible in the SARIF report uploaded to GitHub Security tab — they are suppressed from the fail check, not hidden entirely.
- When a fix becomes available for a previously unfixable CVE, the pipeline will start failing — prompting an upgrade.
- A formal risk register should track unfixed CVEs in production images — `--ignore-unfixed` is not the same as "accepted risk".
- Base image upgrade cadence (monthly minimum) reduces the accumulation of unfixed CVEs over time.
