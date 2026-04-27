# ADR-013: Multi-Stage Dockerfile

## Status

Accepted

## Context

CoverLine's backend image needs build tooling (compilers, package managers) to build the application but should not include those tools in the final image shipped to production. Large images increase pull times, attack surface, and storage costs.

## Decision

Use multi-stage Docker builds: a `builder` stage installs dependencies and compiles the application; a final `runtime` stage copies only the compiled artifacts into a minimal base image (e.g., `python:3.11-slim` or `gcr.io/distroless/python3`).

## Alternatives Considered

| Option | Pros | Cons |
|---|---|---|
| Multi-stage build | Small final image, build tools absent from production, single Dockerfile | Slightly more complex Dockerfile |
| Single-stage build | Simple Dockerfile | Final image contains build tools, dev dependencies, and package caches — large and high attack surface |
| Separate build and runtime Dockerfiles | Explicit separation | Two files to maintain; build artefact must be passed between them manually |

## Consequences

- Final image size reduced by 60–80% compared to single-stage (e.g., 1.2 GB → 200 MB for a Python app with compiled dependencies).
- Trivy image scanning (Phase 5) runs faster on smaller images with fewer installed packages.
- Base image must be pinned to a digest in production to prevent silent upstream changes.
- Distroless or slim images may not include a shell — `kubectl exec` for debugging requires a debug sidecar or an ephemeral container.
