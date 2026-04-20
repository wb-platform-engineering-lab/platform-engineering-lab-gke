# ADR-042: BigQuery Billing Export for CFO Reporting

## Status

Accepted

## Context

The CFO needs month-over-month cost trends per team and product. Kubecost provides real-time allocation but has a 15-day retention limit in the free tier. A queryable historical record of GCP costs is needed for executive reporting.

## Decision

Enable GCP billing export to BigQuery (Standard usage cost export). Store data in a `billing_export` dataset in the `platform-eng-lab-will` project. Analysts query this dataset directly with SQL to produce cost reports.

## Alternatives Considered

| Option | Pros | Cons |
|---|---|---|
| BigQuery billing export | SQL-queryable, permanent history, can join with other BigQuery tables, free to store and query within free tier | 24-hour delay before data appears; requires BigQuery dataset setup via Console (not gcloud CLI) |
| Kubecost CSV export (scheduled) | Available in free tier | 15-day retention only; file-based, not queryable |
| Looker Studio | Visualisation on top of BigQuery | Not a data store — sits on top of BigQuery export |

## Consequences

- BigQuery export is configured via GCP Console (Billing → BigQuery export) — not available via `gcloud` CLI for billing accounts.
- Data begins appearing within 24 hours of enabling — there is no historical backfill.
- Custom Kubernetes labels (`team`, `product`) only appear in the export if `resource_usage_export_config` is enabled in Terraform (GKE resource usage metering must be on).
- The two SQL queries in Phase 10e Challenge 5 are the direct answer to the CFO's original question.
