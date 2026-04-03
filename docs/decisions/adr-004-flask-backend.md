# ADR-004: Python Flask for the Backend Service

## Status

Accepted

## Context

The lab requires a simple backend API to demonstrate containerization, service-to-service communication, and later Kubernetes deployments. A technology had to be chosen for the backend service.

## Decision

Use Python with Flask as the backend API framework.

## Alternatives Considered

| Option | Pros | Cons |
|---|---|---|
| Python + Flask (chosen) | Minimal boilerplate, widely used in DevOps/data tooling, readable for non-backend engineers | Not production-grade for high-throughput APIs |
| Node.js + Express | Same runtime as the frontend, large ecosystem | Redundant with the frontend service in this lab |
| Go | Extremely small binaries, high performance, great for platform tooling | Steeper learning curve, overkill for a demo API |
| FastAPI (Python) | Modern, async, auto-generates OpenAPI docs | Slightly more setup than Flask for a minimal demo |

## Consequences

- Flask's minimal surface area keeps the focus on DevOps skills, not application code
- Python is already commonly used in data pipelines (Phase 9 — Airflow, dbt), so the same language appears consistently across the lab
- The backend is intentionally simple — it is a vehicle for practicing containerization and deployment, not production API design
