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

---

## Troubleshooting

### 1. Frontend returns `Could not reach backend`
**Symptom:** `curl http://localhost:3000/` returns `{"error": "Could not reach backend"}`.

**Cause:** The `BACKEND_URL` environment variable is not being picked up, so the frontend falls back to `http://localhost:5000` — which doesn't exist inside the frontend container.

**Fix:** Make sure you are running via `docker compose up` and not `docker run`. The `BACKEND_URL=http://backend:5000` env var is only injected by docker-compose. Verify with:
```bash
docker exec frontend env | grep BACKEND_URL
```

### 2. Port already in use
**Symptom:** `docker compose up` fails with `Bind for 0.0.0.0:5000 failed: port is already allocated`.

**Fix:** Stop any previously running containers:
```bash
docker compose down
docker ps -a  # find and remove leftover containers
```

### 3. Image not rebuilding after code changes
**Symptom:** Changes to `app.py` or `app.js` are not reflected after restarting.

**Fix:** Force a rebuild:
```bash
docker compose up --build
```
