# Phase 4 — Helm & Microservices

> **Helm concepts introduced:** Chart, Release, Values, Templates, Helpers | **Builds on:** Phase 2 Kubernetes deployments

[📝 Take the quiz](https://wb-platform-engineering-lab.github.io/platform-engineering-lab-gke/phase-4-helm/quiz.html)

---

## Helm concepts introduced

| Concept | What it does | Why we need it |
|---|---|---|
| **Chart** | Packaged collection of Kubernetes manifests with templating | One versioned artifact per service — not a folder of YAML files |
| **Release** | A named instance of a chart installed in the cluster | Multiple environments can run the same chart with different values |
| **Values** | Key-value overrides applied at install or upgrade time | Separates what changes (config) from what doesn't (structure) |
| **Templates** | YAML manifests with Go templating (`{{ .Values.x }}`) | Eliminates copy-paste between environments and services |
| **Helpers (`_helpers.tpl`)** | Named template fragments reused across manifests | Consistent label sets and naming conventions without repetition |

---

## The problem

> *CoverLine — 5,000 members. March.*
>
> The backend team shipped a Redis caching fix on a Tuesday afternoon. By Wednesday morning, the frontend was broken — the fix had changed an API response format that three other services depended on. No one knew which version of the backend was running in production. The Kubernetes YAML files had drifted from what was actually deployed. A hotfix was pushed directly to the cluster by copy-pasting from a Slack message.
>
> The CTO called an all-hands. *"We have four engineers and we already can't tell what's running in production. What happens at 10,000 members?"*

The decision: package everything as Helm charts. One source of truth. Versioned. Rollbackable. No more YAML copy-paste.

---

## Architecture

```
Internet
    └── nginx Ingress
            ├── /        → frontend (Node.js, 2 replicas)
            └── /api/*   → backend  (Python/Flask, 2 replicas)
                                └── GET  /claims  → Redis cache → PostgreSQL
                                └── POST /claims  → PostgreSQL  → invalidate Redis

StatefulSets (Bitnami charts):
  postgresql-0   claims table (id, member_id, amount, description, status, created_at)
  redis-master-0 cache key: claims:all   TTL: 30s
```

Redis sits in front of PostgreSQL for read-heavy claim queries. The 30-second TTL means a POST that writes a new claim will return stale data on the next GET until the cache expires. This is covered in the production considerations.

---

## Repository structure

```
phase-4-helm/
├── charts/
│   ├── backend/
│   │   ├── Chart.yaml              ← chart name, version, appVersion
│   │   ├── values.yaml             ← defaults (image, replicas, resources, Vault config)
│   │   └── templates/
│   │       ├── _helpers.tpl        ← fullname and label helpers
│   │       ├── deployment.yaml     ← templated Deployment
│   │       ├── service.yaml        ← ClusterIP on port 5000
│   │       └── serviceaccount.yaml ← SA for Workload Identity / Vault
│   └── frontend/
│       ├── Chart.yaml
│       ├── values.yaml
│       └── templates/
│           ├── _helpers.tpl
│           ├── deployment.yaml
│           └── service.yaml
└── app/
    ├── backend/
    │   ├── app.py       ← Flask API: /health, /claims (GET + POST), /data
    │   ├── Dockerfile   ← multi-stage, non-root user, read-only filesystem
    │   └── requirements.txt
    └── frontend/
        ├── app.js       ← Express app: calls backend /claims
        └── Dockerfile
```

---

## Prerequisites

GKE cluster from Phase 1 running, `kubectl` configured, nginx Ingress controller from Phase 2 installed:

```bash
kubectl get nodes
helm version   # v3.x required
```

Add the Bitnami chart repository:

```bash
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update
```

---

## Architecture Decision Records

- `docs/decisions/adr-010-helm-over-raw-manifests.md` — Why Helm over plain Kubernetes YAML for packaging
- `docs/decisions/adr-011-bitnami-for-stateful-services.md` — Why Bitnami charts for PostgreSQL and Redis over custom StatefulSets
- `docs/decisions/adr-012-redis-cache-aside.md` — Why cache-aside pattern over write-through for claims caching
- `docs/decisions/adr-013-multi-stage-dockerfile.md` — Why multi-stage builds with non-root users for all application images

---

## Challenge 1 — Deploy PostgreSQL and Redis via Bitnami charts

### Step 1: Deploy PostgreSQL

```bash
helm install postgresql bitnami/postgresql \
  --set auth.username=coverline \
  --set auth.password=coverline123 \
  --set auth.database=coverline \
  --set primary.persistence.size=1Gi
```

Wait for the pod to be ready before continuing:

```bash
kubectl wait pod/postgresql-0 --for=condition=ready --timeout=120s
```

### Step 2: Deploy Redis

```bash
helm install redis bitnami/redis \
  --set auth.enabled=false \
  --set master.persistence.size=1Gi
```

### Step 3: Verify both StatefulSets are running

```bash
helm list
kubectl get pods -l app.kubernetes.io/name=postgresql
kubectl get pods -l app.kubernetes.io/name=redis
```

Expected:
```
NAME         NAMESPACE   REVISION   STATUS     CHART
postgresql   default     1          deployed   postgresql-x.x.x
redis        default     1          deployed   redis-x.x.x
```

---

## Challenge 2 — Explore the backend chart structure

Before installing the chart, understand how it works.

### Step 1: Review `Chart.yaml`

```yaml
# charts/backend/Chart.yaml
apiVersion: v2
name: backend
description: CoverLine claims API
type: application
version: 1.0.0
appVersion: "2.0.0"
```

`version` is the chart version. `appVersion` is the application version. Bumping `version` creates a new Helm release revision — visible in `helm history`.

### Step 2: Review `values.yaml`

```yaml
# charts/backend/values.yaml
replicaCount: 2

image:
  repository: us-central1-docker.pkg.dev/platform-eng-lab-will/coverline/backend
  tag: "b8ff726a196c357daffed70eab9550f670349bff"
  pullPolicy: IfNotPresent

service:
  type: ClusterIP
  port: 5000

db:
  port: 5432

redis:
  port: 6379

resources:
  requests:
    cpu: "100m"
    memory: "128Mi"
  limits:
    cpu: "250m"
    memory: "256Mi"
```

Any value here can be overridden at install time with `--set key=value` or a custom values file — without touching the chart.

### Step 3: Review `templates/_helpers.tpl`

```go
{{- define "backend.fullname" -}}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "backend.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion }}
{{- end }}
```

`backend.fullname` generates a name like `coverline-backend` from the release name and chart name. `backend.labels` stamps every resource with standard labels — used by `helm list` and `kubectl` selectors.

### Step 4: Render the templates without installing

```bash
helm template coverline phase-4-helm/charts/backend/
```

This shows the exact YAML Kubernetes would receive. Use it to verify templating before applying.

---

## Challenge 3 — Install the backend and frontend charts

### Step 1: Install the backend

```bash
helm install coverline phase-4-helm/charts/backend/
```

### Step 2: Install the frontend

```bash
helm install coverline-frontend phase-4-helm/charts/frontend/
```

### Step 3: Verify all releases

```bash
helm list
kubectl get pods
```

Expected — four releases running:
```
NAME                NAMESPACE   REVISION   STATUS     CHART
coverline           default     1          deployed   backend-1.0.0
coverline-frontend  default     1          deployed   frontend-1.0.0
postgresql          default     1          deployed   postgresql-x.x.x
redis               default     1          deployed   redis-x.x.x
```

---

## Challenge 4 — Test the claims API

### Step 1: Port-forward the backend service

```bash
kubectl port-forward svc/coverline-backend 5001:5000 &
```

### Step 2: Check the health endpoint

```bash
curl http://localhost:5001/health
```

Expected: `{"status": "ok"}`

### Step 3: Submit a claim

```bash
curl -X POST http://localhost:5001/claims \
  -H "Content-Type: application/json" \
  -d '{"member_id": "MBR-001", "amount": 150.00, "description": "GP consultation"}'
```

### Step 4: Retrieve claims (first call hits PostgreSQL, subsequent calls hit Redis)

```bash
curl http://localhost:5001/claims
# Look for "source": "db" on first call, "source": "cache" on second
```

---

## Challenge 5 — Upgrade and roll back a release

### Step 1: Scale the backend to 3 replicas

```bash
helm upgrade coverline phase-4-helm/charts/backend/ --set replicaCount=3
```

### Step 2: Verify the rollout

```bash
kubectl get pods -l app.kubernetes.io/instance=coverline
```

You should see 3 backend pods running.

### Step 3: Inspect the release history

```bash
helm history coverline
```

```
REVISION   STATUS      CHART           DESCRIPTION
1          superseded  backend-1.0.0   Install complete
2          deployed    backend-1.0.0   Upgrade complete
```

### Step 4: Roll back to revision 1

```bash
helm rollback coverline 1
helm history coverline
```

```
REVISION   STATUS      CHART           DESCRIPTION
1          superseded  backend-1.0.0   Install complete
2          superseded  backend-1.0.0   Upgrade complete
3          deployed    backend-1.0.0   Rollback to 1
```

Revision 3 is a new deploy of the revision 1 configuration. Kubernetes rolls back to 2 replicas without restarting healthy pods unnecessarily.

---

## Teardown

```bash
helm uninstall coverline coverline-frontend postgresql redis
```

> **Note:** Persistent volume claims are not deleted automatically. Remove them if you want to start fresh:
> ```bash
> kubectl delete pvc --all
> ```

---

## Cost breakdown

Phase 4 adds no GCP costs. PostgreSQL and Redis run as pods on the existing GKE cluster.

| Resource | $/day |
|---|---|
| GKE cluster (Phase 1) | ~$0.66 |
| PostgreSQL pod | included in node cost |
| Redis pod | included in node cost |
| **Phase 4 additional cost** | **$0** |

---

## Helm concept: releases and the revision history

Every `helm install` or `helm upgrade` creates a new **revision** stored as a Kubernetes Secret in the release namespace. This is how `helm rollback` works — it reads the previous revision's manifest and re-applies it.

This has an important implication: Helm history is stored in the cluster, not on disk. If you delete the cluster, the history is gone. In production, chart versions are stored in a registry so you can always reproduce any release from the chart version number alone — without needing the cluster's history.

---

## Production considerations

### 1. Never put secrets in values.yaml
This lab passes the PostgreSQL password via `--set auth.password=coverline123`. In production, secrets must come from Vault (Phase 3) or a secrets manager — never from a values file versioned in Git or passed on the command line where they appear in shell history.

### 2. Use Helmfile for multi-environment management
Helm alone does not handle differences between dev, staging, and prod well. Helmfile defines all releases and per-environment values in a single declarative file:

```yaml
releases:
  - name: coverline
    chart: ./charts/backend
    values:
      - values/{{ .Environment.Name }}.yaml
environments:
  dev:
  prod:
```

### 3. Package and version charts in a registry
This lab references charts by local path. In production, each chart should be packaged, versioned with semver, and published to a private OCI registry (Artifact Registry supports Helm charts natively). This guarantees that every deployment is traceable to a specific chart version.

### 4. Configure PodAntiAffinity for critical workloads
With 2 replicas, both pods can land on the same node. If that node is preempted (spot) or upgraded, both pods disappear simultaneously. Anti-affinity rules distribute replicas across nodes:

```yaml
affinity:
  podAntiAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      - labelSelector:
          matchLabels:
            app.kubernetes.io/name: backend
        topologyKey: kubernetes.io/hostname
```

### 5. Replace PostgreSQL StatefulSet with Cloud SQL in production
The Bitnami PostgreSQL chart is appropriate for a lab. In production, use Cloud SQL — it handles automated backups, point-in-time recovery, read replicas, and failover without you managing the StatefulSet lifecycle.

### 6. Use event-driven cache invalidation
The 30-second Redis TTL is a shortcut. A POST that writes a new claim returns stale data on the next GET until the TTL expires. In production, invalidate the cache key explicitly when data changes — not on a timer.

---

## Outcome

The CoverLine stack runs as four Helm releases: backend, frontend, PostgreSQL, and Redis. Any engineer can inspect exactly what is deployed (`helm list`, `helm history`), upgrade with a single command, and roll back in under 30 seconds. YAML drift and Slack-message hotfixes are no longer possible — every change goes through Helm.

---

[Back to main README](../README.md) | [Next: Phase 5 — CI/CD](../phase-5-ci-cd/README.md)
