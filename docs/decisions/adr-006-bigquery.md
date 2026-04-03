# ADR-006: BigQuery as the Data Warehouse

## Status

Accepted

## Context

Phase 9 (Data Platform) requires a data warehouse to store the output of dbt transformations and Airflow pipelines. A warehouse technology had to be chosen.

## Decision

Use Google BigQuery as the data warehouse, provisioned via Terraform in Phase 1.

## Alternatives Considered

| Option | Pros | Cons |
|---|---|---|
| BigQuery (chosen) | Serverless, native GCP integration, pay-per-query, no cluster to manage | GCP vendor lock-in |
| Snowflake | Multi-cloud, widely used in enterprise | Additional cost on top of GCP, requires separate account |
| Amazon Redshift | Mature, widely adopted | AWS-only, doesn't fit GCP-based lab |
| Self-hosted PostgreSQL | Free, full control | Not a true analytics warehouse, poor performance on large datasets |
| ClickHouse | Extremely fast for analytics | Operational overhead, less ecosystem support |

## Consequences

- BigQuery is provisioned via Terraform alongside the rest of the infrastructure (Phase 1)
- No infrastructure to manage — BigQuery is fully serverless
- Native integration with Airflow (via `BigQueryOperator`) and dbt (`dbt-bigquery` adapter)
- Cost is near-zero for lab-scale data (pay per TB queried, first 1TB/month free)
- Dataset is created in the same GCP project, simplifying IAM
