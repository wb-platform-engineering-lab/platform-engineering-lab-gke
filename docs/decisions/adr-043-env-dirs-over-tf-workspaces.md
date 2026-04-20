# ADR-043: Environment Directories over Terraform Workspaces

## Status

Accepted

## Context

Phase 11 Capstone provisions three GKE clusters: dev, staging, and production. Terraform supports multiple strategies for multi-environment infrastructure: separate directories per environment, or Terraform workspaces using the same root module.

## Decision

Use separate environment directories (`environments/dev/`, `environments/staging/`, `environments/prod/`) each with their own `terraform.tfvars` and backend configuration pointing to separate GCS state files. Share modules (`modules/gke/`) across all environments.

## Alternatives Considered

| Option | Pros | Cons |
|---|---|---|
| Environment directories | Explicit, independent state files, independent apply per environment, easy to read | More files to maintain; module updates must be applied to each directory |
| Terraform workspaces | Single directory, workspace-scoped state | Workspaces share one backend config; accidental `terraform apply` in wrong workspace is a common mistake; harder to enforce environment-specific policies |
| Separate repositories | Total isolation | Too much overhead for 3 closely related environments |

## Consequences

- Each environment has its own GCS state file — a `terraform destroy` in `dev` cannot affect `prod`.
- Non-overlapping VPC CIDR ranges must be planned upfront across all three environments (GKE VPC-native, see ADR-003).
- CI/CD promotes by running `terraform apply` in each directory sequentially: dev → staging → prod.
- Module versioning: all environments use the same module source; a module change is tested in dev before being applied to prod.
