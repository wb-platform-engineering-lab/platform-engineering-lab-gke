# Phase 3 — Helm & Microservices

## What was built

- Packaged backend and frontend as Helm charts with templates, values.yaml, and helpers
- Deployed PostgreSQL and Redis via Bitnami Helm charts as Kubernetes StatefulSets
- Upgraded Flask backend with real `/claims` endpoints reading/writing to PostgreSQL with Redis caching
- Demonstrated `helm upgrade` (scale to 3 replicas) and `helm rollback`
- Full CoverLine stack: frontend → backend → PostgreSQL + Redis

## Architecture

```
frontend (Node.js)
    └── GET /          → calls backend /claims  (Redis cache → PostgreSQL)
    └── POST /claims   → calls backend /claims  (writes to PostgreSQL, invalidates cache)

backend (Python/Flask)
    ├── GET  /claims   → checks Redis → falls back to PostgreSQL → caches result (30s TTL)
    └── POST /claims   → writes to PostgreSQL → invalidates Redis cache

PostgreSQL  → claims table (id, member_id, amount, description, status, created_at)
Redis       → cache key: claims:all (TTL: 30s)
```

## Helm releases

| Release | Chart | Description |
|---|---|---|
| `coverline` | `charts/backend` | CoverLine claims API |
| `coverline-frontend` | `charts/frontend` | CoverLine member portal |
| `postgresql` | `bitnami/postgresql` | PostgreSQL database |
| `redis` | `bitnami/redis` | Redis cache |

## How to deploy

```bash
# Add Bitnami repo
helm repo add bitnami https://charts.bitnami.com/bitnami && helm repo update

# Deploy PostgreSQL and Redis
helm install postgresql bitnami/postgresql \
  --set auth.username=coverline \
  --set auth.password=coverline123 \
  --set auth.database=coverline \
  --set primary.persistence.size=1Gi

helm install redis bitnami/redis \
  --set auth.enabled=false \
  --set master.persistence.size=1Gi

# Deploy backend and frontend
helm install coverline charts/backend/
helm install coverline-frontend charts/frontend/
```

## Verify

```bash
helm list
kubectl get pods

# Port-forward and test
kubectl port-forward svc/coverline-backend 5001:5000 &
curl http://localhost:5001/claims
curl -X POST http://localhost:5001/claims \
  -H "Content-Type: application/json" \
  -d '{"member_id": "member-001", "amount": 150.00, "description": "GP consultation"}'
```

## Helm upgrade and rollback

```bash
# Upgrade — scale to 3 replicas
helm upgrade coverline charts/backend/ --set replicaCount=3

# Check history
helm history coverline

# Rollback to previous revision
helm rollback coverline 1
```

## Teardown

```bash
helm uninstall coverline coverline-frontend postgresql redis
```

---

## Troubleshooting

### 1. Backend pods in `CrashLoopBackOff` — DB connection refused

**Cause:** PostgreSQL not ready yet when backend starts.

**Fix:** Wait for PostgreSQL pod to be `Running` before installing the backend chart:
```bash
kubectl wait pod/postgresql-0 --for=condition=ready --timeout=120s
helm install coverline charts/backend/
```

### 2. `source: cache` returning stale data

**Cause:** Redis cache TTL is 30 seconds — GET returns cached data after a POST.

**Fix:** This is expected behaviour. Wait 30s or restart Redis pod to flush cache during development:
```bash
kubectl delete pod redis-master-0
```

### 3. `password` secret not found

**Cause:** Backend chart reads the PostgreSQL password from the `postgresql` secret created by the Bitnami chart. If PostgreSQL was installed with a different release name, the secret name differs.

**Fix:** Check the secret name and update `values.yaml`:
```bash
kubectl get secrets | grep postgresql
```
