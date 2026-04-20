# ADR-028: Dynamic Database Credentials over Static Passwords

## Status

Accepted

## Context

CoverLine's backend needs credentials to connect to PostgreSQL. Static passwords stored in Kubernetes Secrets have a fixed lifetime and are often shared across services. If a password is compromised, rotation requires coordinating restarts across all consumers.

## Decision

Use Vault's Database Secrets Engine to generate short-lived, per-pod PostgreSQL credentials. Each pod receives a unique username and password that expires after the lease TTL (e.g., 1 hour).

## Alternatives Considered

| Option | Pros | Cons |
|---|---|---|
| Vault dynamic credentials | Unique per pod, short-lived, automatically revoked on pod termination, breach radius is limited to one lease | More complex setup; requires Vault PostgreSQL plugin and role configuration |
| Static password in Kubernetes Secret | Simple | Long-lived, shared, rotation requires coordinated restart, breach is cluster-wide |
| External Secrets Operator + GCP Secret Manager | Managed secret store, rotation via GSM | Still static credentials rotated on a schedule, not per-pod dynamic credentials |

## Consequences

- PostgreSQL must have a Vault management account with `CREATE ROLE` and `GRANT` permissions.
- Vault renews credentials before they expire as long as the pod is running — pod termination revokes them immediately.
- A Vault outage prevents new pods from starting (credential fetch fails) — Vault HA is a production requirement.
- The learning outcome: engineers see that every pod has a different DB username in `pg_stat_activity` — dynamic credentials are visible and traceable.
