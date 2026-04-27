# ADR-009: ConfigMap for Environment Configuration

## Status

Accepted

## Context

CoverLine services need environment-specific configuration: database hostnames, Redis endpoints, feature flags, and API base URLs. These values differ between dev and production environments and must not be hardcoded into container images.

## Decision

Store non-secret configuration in Kubernetes `ConfigMap` objects and inject them into pods as environment variables or volume mounts. Store secrets (passwords, API keys) in Kubernetes `Secret` objects (and Vault in Phase 3).

## Alternatives Considered

| Option | Pros | Cons |
|---|---|---|
| ConfigMap env injection | Kubernetes-native, readable YAML, diff-able in git | Values are plaintext — must not contain secrets |
| Hardcoded in image | Simple | Environment-specific config baked into image; can't promote the same image across envs |
| External config server | Centralised, dynamic | Additional service to operate; over-engineered for a single cluster |

## Consequences

- ConfigMaps are stored in version control alongside the Helm charts that reference them.
- The same Docker image is used across all environments — only the ConfigMap values change per environment.
- Secrets are explicitly excluded from ConfigMaps; any secret accidentally placed in a ConfigMap must be rotated immediately.
- Helm values files (per-environment `values-dev.yaml`, `values-prod.yaml`) generate the ConfigMap contents.
