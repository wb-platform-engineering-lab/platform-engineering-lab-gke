# ADR-017: Trivy for Container Image Scanning in CI

## Status

Accepted

## Context

Container images may include base image layers or dependencies with known CVEs. These vulnerabilities should be caught in CI before images are pushed to the registry, not discovered post-deployment in production.

## Decision

Run Trivy as a GitHub Actions step after `docker build` and before `docker push`. Fail the pipeline on `HIGH` or `CRITICAL` severity CVEs with fixes available (`--exit-code 1 --severity HIGH,CRITICAL --ignore-unfixed`).

## Alternatives Considered

| Option | Pros | Cons |
|---|---|---|
| Trivy | Fast, no daemon required, covers OS packages + language deps, free | May produce false positives; `--ignore-unfixed` needed to reduce noise |
| Snyk | Rich dashboard, developer-friendly | Requires account; free tier rate-limited |
| GCR Vulnerability Scanning | Integrates with GCP Artifact Registry | Only scans after push — too late to block the pipeline |
| No scanning | Zero overhead | Known CVEs silently shipped to production |

## Consequences

- `--ignore-unfixed` filters CVEs where no patched version exists — reduces noise but means unfixable CVEs pass through.
- CI time increases by ~30–60 seconds per image scan.
- Base image updates (e.g., `python:3.11-slim` → new patch) happen when new CVEs are published for the current version.
- Trivy results are uploaded as a SARIF report to GitHub Security tab for historical visibility (Phase 4 pipeline).
