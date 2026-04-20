# ADR-045: Backstage IDP over Internal Wiki for Service Catalogue

## Status

Accepted

## Context

Phase 11 Capstone requires a centralised place where engineers can discover services, their owners, API contracts, CI/CD pipelines, and infrastructure dependencies. Without this, engineers spend hours asking Slack to find who owns a service or where its runbook is.

## Decision

Install Backstage (Spotify's open-source Internal Developer Platform) as the service catalogue. Each service defines a `catalog-info.yaml` at its repository root. Backstage discovers and indexes these via a GitHub integration.

## Alternatives Considered

| Option | Pros | Cons |
|---|---|---|
| Backstage | Dynamic catalogue (syncs from git), built-in TechDocs, plugin ecosystem (PagerDuty, GCP, ArgoCD), industry standard IDP | Complex to operate (Node.js app + PostgreSQL backend); plugins require configuration |
| Confluence / internal wiki | Familiar, already licensed | Static — goes stale as soon as the page is written; no integration with live deployment data |
| README files only | Zero overhead | No discoverability — requires knowing a repo exists to find it |

## Consequences

- Each service needs a `catalog-info.yaml` with `kind: Component`, `owner`, `lifecycle`, and `links` fields.
- Backstage runs in the `backstage` namespace — requires a PostgreSQL database for its catalogue backend.
- GitHub integration requires a GitHub App token to read `catalog-info.yaml` files from all repositories.
- TechDocs (Backstage's documentation plugin) renders Markdown from the repo alongside the catalogue entry — replaces the need for a separate wiki for service documentation.
