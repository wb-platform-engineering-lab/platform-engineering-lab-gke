# ADR-027: Vault on a GCP VM, Not Inside Kubernetes

## Status

Accepted

## Context

Phase 7 introduces HashiCorp Vault for secrets management. Vault itself needs to run somewhere. Running Vault inside Kubernetes creates a circular dependency: Kubernetes secrets are needed to bootstrap Vault, but Vault is the secrets manager.

## Decision

Run Vault on a dedicated GCP Compute Engine VM (`e2-micro`) outside the GKE cluster. The Vault Agent Injector runs inside GKE and communicates with the external Vault server over the private VPC network.

## Alternatives Considered

| Option | Pros | Cons |
|---|---|---|
| Vault on GCP VM | No circular bootstrap dependency; Vault survives cluster recreation; cleaner separation | Additional VM to manage; Vault HA requires multiple VMs and a load balancer |
| Vault on Kubernetes (StatefulSet) | Kubernetes-managed, consistent tooling | Bootstrap problem: need secrets to unseal Vault, but Vault holds the secrets; complex HA setup |
| GCP Secret Manager | Fully managed, no ops burden | Not Vault — doesn't teach dynamic credentials, policies, or the Vault Agent pattern |

## Consequences

- Vault VM is accessible from GKE nodes via private VPC IP — no public IP needed.
- GCP KMS is used for auto-unseal (see ADR-030) so Vault recovers automatically after VM restart.
- VM maintenance (patching, snapshots) is a manual responsibility — a production Vault deployment uses Vault Enterprise on VMs with autoscaling.
- Vault Agent Injector (ADR-029) handles credential injection into pods — application code never calls the Vault API directly.
