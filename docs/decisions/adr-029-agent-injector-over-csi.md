# ADR-029: Vault Agent Injector over CSI Secrets Driver

## Status

Accepted

## Context

Vault credentials need to reach pods. Two primary integration patterns exist: the Vault Agent Injector (mutating webhook that injects a sidecar) and the Secrets Store CSI Driver (mounts secrets as volumes via the CSI interface).

## Decision

Use the Vault Agent Injector. Annotate pods with `vault.hashicorp.com/agent-inject: "true"` and credential-specific annotations. The injector adds an init container and a sidecar container that handle Vault authentication and credential renewal.

## Alternatives Considered

| Option | Pros | Cons |
|---|---|---|
| Vault Agent Injector | No application code changes; handles renewal automatically; works with any language | Adds two containers per pod (init + sidecar); mutating webhook required |
| Secrets Store CSI Driver | Standard Kubernetes volume interface; works with multiple secret backends | Requires CSI driver installation; secret rotation requires pod restart or `secretProviderClass` rotation config |
| Direct Vault API calls | Application fully controls credential lifecycle | Application must implement Vault auth, renewal logic, and error handling in every language |

## Consequences

- Every annotated pod gets two additional containers — `vault-agent-init` (init) and `vault-agent` (sidecar).
- Credentials are written to `/vault/secrets/<name>` as files — application reads credentials from the filesystem, not environment variables.
- Sidecar renews credentials before TTL expiry — pods don't need to handle renewal.
- If the Vault Agent Injector webhook is unavailable, new pods cannot start — high availability is a production requirement.
