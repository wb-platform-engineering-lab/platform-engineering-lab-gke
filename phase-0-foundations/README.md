# Phase 0 — Foundations

## What was built

A two-service application running locally with Docker Compose:

- **Backend** — Python Flask API (`/health`, `/data`)
- **Frontend** — Node.js Express app that calls the backend over a Docker network

## Key concepts practiced

- Multi-stage Docker builds to minimize image size
- Docker networking — services communicate using container names as hostnames (not `localhost`)
- Environment variable injection via `docker-compose.yml`
- `depends_on` to control startup order

## Image size comparison

| Service | Before (single-stage) | After (multi-stage) | Reduction |
|---|---|---|---|
| Backend (Python) | 1.62GB | 210MB | ~87% |
| Frontend (Node.js) | — | 310MB | built optimized from start |

## How to run

```bash
docker compose up --build
```

## Verify

```bash
# Backend health
curl http://localhost:5000/health

# Frontend health
curl http://localhost:3000/health

# Frontend calling backend (service-to-service)
curl http://localhost:3000/
```

## Teardown

```bash
docker compose down
```
