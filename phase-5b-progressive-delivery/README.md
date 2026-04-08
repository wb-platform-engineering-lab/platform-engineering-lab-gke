# Phase 5b — Progressive Delivery (Argo Rollouts)

---

> **CoverLine — 20,000 members. November.**
>
> The claims service had a bug that only appeared under load. A developer fixed it, the CI pipeline passed, and ArgoCD deployed it to production in 30 seconds.
>
> The bug was in the database connection pool. Under low traffic, it was invisible. At 20% of production load, it started leaking connections. By the time the on-call engineer saw the Grafana alert, all 20 connections were exhausted and the claims API was returning 500s for every member.
>
> The rollback took 4 minutes. 3,200 members saw errors.
>
> The post-mortem asked one question: *"How do we catch a bug that only shows at real traffic levels — before it reaches 100% of users?"*
>
> The answer: progressive delivery. Deploy to 5% of users first. Watch the error rate. If it's clean, promote to 20%, then 50%, then 100%. If anything looks wrong, roll back automatically — before most users ever see it.

---

## What we'll build

| Component | What it does |
|-----------|-------------|
| **Argo Rollouts** | Replaces Kubernetes Deployments with progressive delivery primitives |
| **Canary release** | Route 5% → 20% → 50% → 100% of traffic to the new version |
| **Analysis Templates** | Automatically query Prometheus during rollout — fail if error rate > 1% |
| **Automated rollback** | Argo Rollouts rolls back without human intervention if analysis fails |
| **Rollouts Dashboard** | Visualise canary progress in real time |

---

## Prerequisites

Phase 5 (ArgoCD) must be complete. Verify:
```bash
kubectl get pods -n argocd
kubectl get applications -n argocd
```

---

## Step 1 — Install Argo Rollouts

```bash
kubectl create namespace argo-rollouts
kubectl apply -n argo-rollouts -f https://github.com/argoproj/argo-rollouts/releases/latest/download/install.yaml
```

Verify:
```bash
kubectl get pods -n argo-rollouts -w
```

Expected: `argo-rollouts-controller-*` in `Running` state.

Install the kubectl plugin (used to inspect and promote rollouts):
```bash
brew install argoproj/tap/kubectl-argo-rollouts
```

Verify:
```bash
kubectl argo rollouts version
```

---

## Step 2 — Install the Rollouts Dashboard

The dashboard gives a live view of canary progress — traffic split, analysis status, pod health.

```bash
kubectl apply -n argo-rollouts -f https://github.com/argoproj/argo-rollouts/releases/latest/download/dashboard-install.yaml
```

Access it:
```bash
kubectl port-forward svc/argo-rollouts-dashboard -n argo-rollouts 3100:3100 &
```

Open `http://localhost:3100` — it's empty for now, will populate in Step 4.

---

## Step 3 — Convert the Backend Deployment to a Rollout

Argo Rollouts works by replacing the standard Kubernetes `Deployment` with a `Rollout` resource. The pod spec is identical — only the rollout strategy changes.

Apply the Rollout for the backend:

```bash
kubectl apply -f phase-5b-progressive-delivery/rollout-backend.yaml
```

> **Note:** The existing `coverline-backend` Deployment must be deleted first — Argo Rollouts manages its own ReplicaSets and conflicts with a live Deployment of the same name.

```bash
kubectl delete deployment coverline-backend
kubectl apply -f phase-5b-progressive-delivery/rollout-backend.yaml
```

Verify the Rollout is healthy:
```bash
kubectl argo rollouts get rollout coverline-backend -w
```

Expected output:
```
Name:            coverline-backend
Namespace:       default
Status:          ✔ Healthy
Strategy:        Canary
  Step:          8/8
  SetWeight:     100
  ActualWeight:  100
```

---

## Step 4 — Create the Analysis Template

The Analysis Template defines what "healthy" means during a canary rollout. Argo Rollouts will query Prometheus automatically at each canary step and fail the rollout if the error rate exceeds the threshold.

```bash
kubectl apply -f phase-5b-progressive-delivery/analysis-template.yaml
```

Verify:
```bash
kubectl get analysistemplate
```

Expected:
```
NAME                    AGE
coverline-error-rate    5s
```

---

## Step 5 — Trigger a Canary Rollout

Trigger a new rollout by updating the image tag. This simulates a normal deploy:

```bash
kubectl argo rollouts set image coverline-backend \
  backend=ghcr.io/wb-platform-engineering-lab/coverline-backend:v2.0.0
```

Watch the canary progress in real time (open a second terminal):
```bash
kubectl argo rollouts get rollout coverline-backend -w
```

Expected progression:
```
Name:            coverline-backend
Status:          ॥ Paused
Strategy:        Canary
  Step:          1/8
  SetWeight:     5
  ActualWeight:  5
Canary Pods:     1
Stable Pods:     9
```

Open the dashboard at `http://localhost:3100` to see the live traffic split visualisation.

---

## Step 6 — Observe the Canary Steps

The rollout pauses at each step defined in `rollout-backend.yaml`:

| Step | Traffic to canary | Duration | Action |
|------|-------------------|----------|--------|
| 1 | 5% | Pause 2min | Manual inspect |
| 2 | 5% | Analysis runs | Auto: check error rate |
| 3 | 20% | Pause 2min | Manual inspect |
| 4 | 20% | Analysis runs | Auto: check error rate |
| 5 | 50% | Pause 2min | Manual inspect |
| 6 | 50% | Analysis runs | Auto: check error rate |
| 7 | 100% | — | Promote complete |

### Manually promote a step (if paused waiting for approval)

```bash
kubectl argo rollouts promote coverline-backend
```

### Abort and roll back immediately

```bash
kubectl argo rollouts abort coverline-backend
```

### Check analysis run results

```bash
kubectl get analysisrun
kubectl describe analysisrun <name>
```

---

## Step 7 — Simulate a Bad Deploy (Automated Rollback)

Trigger a rollout with a version that has a high error rate to see automated rollback in action:

```bash
kubectl argo rollouts set image coverline-backend \
  backend=ghcr.io/wb-platform-engineering-lab/coverline-backend:v2.0.0-broken
```

Watch Argo Rollouts detect the error rate breach and roll back automatically:

```bash
kubectl argo rollouts get rollout coverline-backend -w
```

Expected output after the analysis fails:
```
Status:          ✖ Degraded
Message:         RolloutAborted: AnalysisRun coverline-backend-xxx failed
Strategy:        Canary
  Step:          2/8
  SetWeight:     5
```

The rollout automatically reverts all traffic to the stable version. No human intervention required.

---

## Step 8 — Integrate With ArgoCD

To use Argo Rollouts through ArgoCD (GitOps flow), install the Argo Rollouts ArgoCD extension:

```bash
kubectl apply -n argocd -f https://github.com/argoproj/argo-rollouts/releases/latest/download/argo-rollouts-argocd-extension.yaml
```

Update the ArgoCD Application to track the Rollout resource instead of the Deployment:

```bash
kubectl patch application coverline-backend -n argocd \
  --type merge \
  -p '{"spec":{"syncPolicy":{"syncOptions":["RespectIgnoreDifferences=true"]}}}'
```

Now a `git push` to the backend chart triggers a canary rollout through ArgoCD — the full GitOps loop with progressive delivery.

---

## Key Files

| File | Purpose |
|------|---------|
| `rollout-backend.yaml` | Replaces the backend Deployment — defines canary steps and analysis hooks |
| `analysis-template.yaml` | Prometheus query that runs at each analysis step |
| `service-stable.yaml` | Service pointing to stable pods only (used for baseline traffic) |
| `service-canary.yaml` | Service pointing to canary pods only (used for canary traffic) |

---

## How It Works

```
git push → ArgoCD syncs → Argo Rollouts starts canary
                                    │
                         ┌──────────▼──────────┐
                         │  5% traffic → canary │
                         │  95% traffic → stable│
                         └──────────┬──────────┘
                                    │
                         ┌──────────▼──────────┐
                         │  Analysis runs       │
                         │  Query Prometheus:   │
                         │  error_rate < 1%?    │
                         └──────┬────────┬──────┘
                                │        │
                            ✔ pass    ✖ fail
                                │        │
                         promote to   auto rollback
                           20%...       to stable
                          → 50%...
                          → 100%
```

---

## Production Best Practices

### Use Prometheus Metrics That Reflect Real User Impact

Avoid generic CPU/memory metrics in your Analysis Templates. Query what users actually experience:

```yaml
# Good — reflects user-facing errors
rate(http_requests_total{service="backend",status=~"5.."}[2m])
  /
rate(http_requests_total{service="backend"}[2m])

# Better — p99 latency degradation
histogram_quantile(0.99, rate(http_request_duration_seconds_bucket{service="backend"}[2m]))
```

---

### Combine Canary With Blue/Green for Stateful Services

Canary works well for stateless services. For services with database migrations or breaking schema changes, use **blue/green** instead — spin up a complete new environment, run migration, then cut over:

```yaml
strategy:
  blueGreen:
    activeService: coverline-backend
    previewService: coverline-backend-preview
    autoPromotionEnabled: false   # always require manual promotion for DB changes
    prePromotionAnalysis:
      templates:
        - templateName: coverline-error-rate
```

---

### Set `revisionHistoryLimit` to Keep Rollback Options

```yaml
spec:
  revisionHistoryLimit: 5  # keep last 5 ReplicaSets for instant rollback
```

---

### Mirror Traffic for Zero-Risk Canary Testing

For very high-stakes changes (pricing engine, claims calculator), use traffic mirroring instead of live canary traffic — send a copy of production requests to the new version without users seeing the responses:

```yaml
steps:
  - setMirrorRoute:
      name: mirror-route
      percentage: 100   # copy 100% of traffic to canary, users see stable only
  - pause: {duration: 5m}
  - setWeight: 5        # only then start serving real users
```

---

## Troubleshooting

### Rollout stuck at `Paused` indefinitely

**Cause:** No `autoPromotionSeconds` set and no manual promote issued.

```bash
kubectl argo rollouts promote coverline-backend
```

### Analysis fails with `no data points`

**Cause:** Prometheus has no metrics for the canary pods yet — the canary hasn't received enough traffic to generate data.

**Fix:** Increase the analysis `initialDelay` to give the canary time to warm up:
```yaml
analysis:
  startingStep: 1
  templates:
    - templateName: coverline-error-rate
  args:
    - name: service-name
      value: coverline-backend
```

### `Rollout` and `Deployment` conflict

**Cause:** A Deployment and a Rollout with the same name both exist — they both try to manage ReplicaSets with the same selector.

**Fix:**
```bash
kubectl delete deployment coverline-backend
kubectl argo rollouts restart coverline-backend
```

### ArgoCD shows Rollout as `OutOfSync`

**Cause:** ArgoCD doesn't understand the `Rollout` CRD by default and tries to reconcile it as a Deployment.

**Fix:** Install the Argo Rollouts ArgoCD extension (Step 8) and add the Rollout resource to the ArgoCD Application's `ignoreDifferences`.
