# ADR-039: dbt for Data Transformations over Stored Procedures

## Status

Accepted

## Context

Phase 9's data platform needs to transform raw claims and member data loaded into BigQuery into analytics-ready tables. Transformations can live in the database as stored procedures or views, or in an external tool with version control and testing.

## Decision

Use dbt (data build tool) for all BigQuery transformations. dbt models are SQL `SELECT` statements stored as `.sql` files in version control. dbt handles dependency resolution, incremental materialization, and data testing.

## Alternatives Considered

| Option | Pros | Cons |
|---|---|---|
| dbt | SQL-native, version-controlled, built-in data tests, lineage graph, CI integration | Another tool to learn and operate; dbt Cloud for scheduling vs using Airflow to trigger dbt |
| BigQuery stored procedures | Native to BigQuery, no extra tool | No version control, no lineage tracking, no built-in testing, hard to review |
| Spark (Dataproc) | Handles non-SQL transformations, large-scale | Overkill for SQL-expressible transformations; cluster management overhead |

## Consequences

- dbt models live in `phase-9-data-platform/dbt/models/` and are run via Airflow `BashOperator` or `KubernetesPodOperator`.
- `dbt test` runs after each `dbt run` to validate not-null, unique, and referential integrity constraints.
- dbt generates a lineage graph (`dbt docs generate`) showing which tables feed which — useful for impact analysis.
- BigQuery costs are incurred per `dbt run` based on data scanned — incremental models reduce cost as tables grow.
