# ADR-005: Docker Compose for Local Orchestration

## Status

Accepted

## Context

Phase 0 requires running multiple containers locally with service-to-service communication. A tool was needed to manage this without the overhead of a full Kubernetes cluster.

## Decision

Use Docker Compose (v2) for local multi-container orchestration.

## Alternatives Considered

| Option | Pros | Cons |
|---|---|---|
| Docker Compose v2 (chosen) | Industry standard, simple syntax, built into Docker Desktop, shared networks out of the box | Not suitable for production |
| Podman Compose | Daemonless, rootless containers | Less mature, not as widely adopted in teams |
| Minikube / kind | Real Kubernetes locally | Overkill for Phase 0 — adds Kubernetes complexity before fundamentals are solid |
| Manual `docker run` | No extra tooling | No shared networking, no lifecycle management, not reproducible |

## Consequences

- A single `docker compose up --build` command starts the full local stack
- Services communicate using container names as hostnames (Docker internal DNS) — this mirrors how Kubernetes DNS works, making the transition to Phase 2 more intuitive
- `docker-compose.yml` serves as living documentation of the local environment
- Not used beyond Phase 0 — from Phase 2 onwards, Kubernetes handles orchestration
