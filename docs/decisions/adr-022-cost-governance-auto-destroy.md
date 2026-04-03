# ADR-022: Cost Governance — Automated Nightly Destroy

## Status

Accepted

## Context

Running a GKE cluster costs $5–20/day. Without automated teardown, a forgotten session can accumulate $100–600/month in charges. A cost governance strategy was needed to prevent runaway GCP costs during active lab development.

Three approaches were considered: manual teardown, a GitHub Actions scheduled workflow, and a GCP-native Cloud Run Job triggered by Cloud Scheduler.

## Decision

Use a GitHub Actions scheduled workflow (`.github/workflows/auto-destroy.yml`) as the primary cost control mechanism, running `terraform destroy` nightly at 8 PM UTC. A Cloud Run Job + Cloud Scheduler is documented as a Phase 1 bonus challenge to demonstrate GCP-native automation skills.

## Alternatives Considered

| Option | Pros | Cons |
|---|---|---|
| Manual `terraform destroy` | No setup required | Relies on developer discipline — forgotten sessions cause cost overruns |
| GitHub Actions scheduled workflow (chosen) | Free, already in repo, visible in CI history, easy `AUTO_DESTROY_ENABLED` toggle | Requires GitHub secrets for GCP credentials, runs outside GCP |
| Cloud Run Job + Cloud Scheduler | GCP-native, no GitHub secrets, demonstrates Terraform + Cloud Run skills | Additional infra to manage, small Cloud Run cost (~$0), more complex setup |
| GCP Budget Alerts only | Proactive notification | Does not stop resources, only alerts after spending occurs |

## Consequences

- GitHub Actions workflow runs nightly at 8 PM UTC and destroys all Terraform-managed resources
- `AUTO_DESTROY_ENABLED` repository variable can be set to `false` to pause destruction during multi-day phases
- Manual `workflow_dispatch` trigger requires typing "DESTROY" to prevent accidental runs
- The workflow checks resource count before running destroy — skips cleanly if nothing is provisioned
- GitHub Step Summary provides a destruction audit trail for every run
- Cloud Run Job bonus challenge (Phase 1) teaches `google_cloud_run_v2_job`, `google_cloud_scheduler_job`, and Workload Identity — skills that appear in the GCP ACE and GCP Professional Cloud DevOps Engineer exams
- This is a lab trade-off: in production, cost governance uses GCP Budget Alerts + org-level policies, not scheduled destroy
