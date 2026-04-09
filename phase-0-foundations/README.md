# Phase 0 — Foundations

---

> **CoverLine — 0 members. Day one.**
>
> Two founders. A rented desk in a co-working space in Paris. One laptop.
>
> The idea was simple: build the health insurance platform that actually works for people. No paper forms. No fax machines. No calling a hotline and waiting 45 minutes. Just a clean app, instant claims, and real customer support.
>
> The MVP took six weeks. A Python backend, a Node.js frontend, a PostgreSQL database. It ran perfectly — on one machine, in one terminal window, with three `docker run` commands that only the CTO had memorised.
>
> Then an investor asked for a demo. The co-founder tried to run it on her laptop. It didn't start.
>
> *"It works on mine,"* said the CTO.
>
> They rescheduled the demo. That weekend, they containerised everything properly.

---

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


---

[📝 Take the Phase 0 quiz](https://wb-platform-engineering-lab.github.io/platform-engineering-lab-gke/phase-0-foundations/quiz.html)
