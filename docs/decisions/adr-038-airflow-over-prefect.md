# ADR-038: Apache Airflow over Prefect for Pipeline Orchestration

## Status

Accepted

## Context

Phase 9 introduces a data platform for CoverLine's analytics team. The data pipeline (ingest → transform → load) needs an orchestrator to schedule, monitor, and retry tasks. Airflow and Prefect are the two most-evaluated open-source options.

## Decision

Use Apache Airflow (deployed via the official Helm chart) as the pipeline orchestrator. DAGs are defined as Python code and stored in a git repository.

## Alternatives Considered

| Option | Pros | Cons |
|---|---|---|
| Apache Airflow | Mature, widely adopted, strong GCP integration (GKEPodOperator, BigQueryOperator), large operator ecosystem | Complex to operate (scheduler, webserver, workers, metadata DB); UI dated |
| Prefect | Modern Python API, simpler local development, built-in UI | Smaller operator ecosystem; less GCP-native integration; Prefect Cloud for managed version |
| Cloud Composer | Fully managed Airflow on GCP | Expensive (~$300/month minimum); overkill for a lab |

## Consequences

- Airflow runs in the `airflow` namespace with a PostgreSQL metadata database (Bitnami chart).
- DAGs are version-controlled in `phase-9-data-platform/airflow/dags/` and synced via a git-sync sidecar.
- GKEPodOperator spawns isolated pods for each task — Airflow worker doesn't need the task's Python dependencies installed.
- KubernetesExecutor is used instead of CeleryExecutor — each task runs in its own pod, providing natural isolation and autoscaling.
