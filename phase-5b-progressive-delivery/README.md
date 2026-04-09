# Phase 5b — Progressive Delivery (Argo Rollouts)

---

> **CoverLine — 20,000 members. A Thursday afternoon.**
>
> The backend team shipped a new claims processing feature at 2:30 PM. ArgoCD synced the Helm chart in 45 seconds. The Deployment rolled out to 100% of pods in under 3 minutes. Everything looked green.
>
> At 2:48 PM, Karim noticed the error rate on the Grafana dashboard had climbed from 0.2% to 12.4%. The new release had introduced a silent regression in the claims submission endpoint — it failed for any member with more than 5 dependents. Roughly 8% of CoverLine's member base.
>
> The team rolled back at 3:06 PM. 18 minutes of degraded service. 1,600 members affected. Two enterprise client success managers received escalation emails before the engineers knew there was a problem.
>
> The post-mortem question was simple: *"Why did 100% of traffic hit the new version before we verified it worked?"*
>
> *"We need a way to ship to 10% of traffic, watch the error rate for 5 minutes, and only proceed if metrics are healthy. If anything looks wrong, roll back automatically — before we even have time to notice."*

> **▶ [Watch the incident unfold →](https://wb-platform-engineering-lab.github.io/platform-engineering-lab-gke/phase-5b-progressive-delivery/incident-animation.html)**
> *(animated dashboard — no install required)*

---

## End-to-end delivery workflow

From a merged pull request to production — zero manual steps:

```
Developer opens PR → review → merge to main
        │
        ▼
GitHub Actions (cd.yml)
  ├── Build backend image
  ├── Push to Artifact Registry  (us-central1-docker.pkg.dev/.../backend:<sha>)
  ├── Update tag in phase-3-helm/charts/backend/values.yaml
  └── Commit + push values.yaml back to Git
        │
        ▼
ArgoCD detects values.yaml change (polls every 3 min or via webhook)
  └── Syncs Helm chart to cluster
        │
        ▼
Argo Rollouts intercepts — starts canary
  ├── 10% traffic → new version
  ├── pause 2 minutes
  ├── AnalysisTemplate queries Prometheus (success rate ≥ 99%?)
  │     ├── ✔ pass → advance to 30%
  │     └── ✖ fail → rollback to stable immediately
  ├── 30% traffic → new version
  ├── pause 2 minutes
  ├── AnalysisTemplate queries Prometheus again
  │     ├── ✔ pass → advance to 100%
  │     └── ✖ fail → rollback to stable immediately
  └── 100% traffic → rollout complete, stable pointer updated
```

> **What changed vs Phase 5 (GitOps only):**
> Phase 5 syncs 100% of traffic to the new version in one step. Phase 5b intercepts that sync and gates promotion on live production metrics. A bad release never reaches more than 10% of members before being rolled back automatically.

---

## What we'll build

| Component | What it does |
|-----------|-------------|
| **Argo Rollouts controller** | Replaces the default Kubernetes rollout mechanism with progressive delivery |
| **Canary strategy** | Ships to 10% → 30% → 100% with a 2-minute pause at each step |
| **AnalysisTemplate** | Queries Prometheus every 30s — gates promotion on HTTP success rate ≥ 99% |
| **Automatic rollback** | If the analysis fails, traffic is immediately shifted back to the stable version |
| **ArgoCD integration** | Rollouts become the deployment mechanism within the existing GitOps flow |

---

## Prerequisites

Cluster running with Phase 5 (ArgoCD + coverline-backend deployed):
```bash
cd phase-1-terraform && terraform apply
gcloud container clusters get-credentials platform-eng-lab-will-gke \
  --region us-central1 --project platform-eng-lab-will
bash bootstrap.sh --phase 5b
```

Verify ArgoCD and the backend are healthy:
```bash
kubectl get applications -n argocd
kubectl get pods -l app.kubernetes.io/name=backend
```

---

## Step 1 — Install Argo Rollouts

### Install the controller

```bash
kubectl create namespace argo-rollouts
kubectl apply -n argo-rollouts \
  -f https://github.com/argoproj/argo-rollouts/releases/latest/download/install.yaml
kubectl get pods -n argo-rollouts -w
```

Expected: `argo-rollouts-<hash>` pod reaches `Running`.

### Install the kubectl plugin

```bash
brew install argoproj/tap/kubectl-argo-rollouts
```

Verify:
```bash
kubectl argo rollouts version
```

---

## Step 2 — Convert the Deployment to a Rollout

Argo Rollouts uses a `Rollout` custom resource that mirrors the Deployment spec but adds a `strategy` block. The existing `coverline-backend` Deployment must be replaced.

### Why replace, not patch?

A `Rollout` and a `Deployment` managing the same pods will conflict — both will try to own the ReplicaSets. The cleanest approach is to delete the Deployment and apply the Rollout in its place.

```bash
# Remove the existing Deployment
kubectl delete deployment coverline-backend

# Apply the Rollout
kubectl apply -f phase-5b-progressive-delivery/rollout.yaml
```

Watch it come up:
```bash
kubectl argo rollouts get rollout coverline-backend --watch
```

Expected output:
```
Name:            coverline-backend
Namespace:       default
Status:          ✔ Healthy
Strategy:        Canary
  Step:          6/6
  SetWeight:     100
  ActualWeight:  100
Replicas:
  Desired:       2
  Current:       2
  Updated:       2
  Ready:         2
  Available:     2
```

---

## Step 3 — Create the AnalysisTemplate

The AnalysisTemplate defines the Prometheus query that acts as a promotion gate. Before traffic advances from 10% to 30%, and from 30% to 100%, the analysis must pass.

```bash
kubectl apply -f phase-5b-progressive-delivery/analysis-template.yaml
kubectl get analysistemplate
```

Expected:
```
NAME                     AGE
coverline-success-rate   5s
```

Inspect what the analysis will measure:
```bash
kubectl describe analysistemplate coverline-success-rate
```

The template queries `kube_pod_container_status_ready` from kube-state-metrics — a metric that is always present without any app instrumentation. It checks that all canary pods are in a ready state. If any canary pod becomes unready (crash, OOM, failed probe), the analysis fails and the rollback fires.

> **Note:** In production with a properly instrumented app, replace this with an HTTP success rate query:
> ```promql
> sum(rate(http_requests_total{namespace="default",job="coverline-backend",status!~"5.."}[2m]))
> /
> sum(rate(http_requests_total{namespace="default",job="coverline-backend"}[2m]))
> ```
> This requires the app to expose a `/metrics` endpoint (e.g. via `prometheus-flask-exporter` for Python). The `kube_pod_container_status_ready` gate is a reliable baseline for any app regardless of instrumentation.

---

## Step 4 — Deploy a new version (green path)

Simulate shipping a new release by updating the image tag. This triggers the canary rollout.

```bash
kubectl argo rollouts set image coverline-backend \
  backend=us-central1-docker.pkg.dev/platform-eng-lab-will/coverline/backend:v2-good

kubectl argo rollouts get rollout coverline-backend --watch
```

### What you'll observe

| Time | What happens |
|------|-------------|
| 0s | Rollout starts — 1 canary pod created (10% weight) |
| ~10s | Analysis begins — Prometheus queried every 30s |
| 2min | Analysis passes — weight advances to 30% |
| 4min | Analysis passes again — weight advances to 100% |
| ~5min | Old pods terminated — rollout complete |

Watch traffic weights in real time:
```bash
# In a second terminal
watch kubectl argo rollouts get rollout coverline-backend
```

---

## Step 5 — Simulate a bad deploy (automatic rollback)

Now simulate the Thursday afternoon incident: ship a broken version and watch the automatic rollback fire before you have time to notice.

```bash
kubectl argo rollouts set image coverline-backend \
  backend=us-central1-docker.pkg.dev/platform-eng-lab-will/coverline/backend:v3-broken
```

Watch the analysis fail and rollback trigger:
```bash
kubectl argo rollouts get rollout coverline-backend --watch
```

Expected sequence:
```
Status:  ॥ Paused
Message: CanaryPauseStep

... (30s later, analysis fires)

Status:  ✖ Degraded
Message: RolloutAborted: metric "success-rate" assessed Failed due to failed (1) > failureLimit (0)
```

Verify traffic is back on the stable version:
```bash
kubectl argo rollouts get rollout coverline-backend
# SetWeight: 0  ← canary traffic removed
# ActualWeight: 0
```

### Check the AnalysisRun that triggered the rollback

```bash
kubectl get analysisrun
kubectl describe analysisrun <name>
```

The AnalysisRun log shows the exact Prometheus query result that caused the failure — the same data Karim would have seen on Grafana, but acted on automatically.

---

## Step 6 — ArgoCD integration

With Argo Rollouts installed, ArgoCD automatically detects Rollout resources and integrates with them. The ArgoCD UI shows canary progress, weight percentages, and analysis status alongside the standard sync state.

### Update the ArgoCD application to track the Rollout

The existing ArgoCD Application in `phase-5-gitops/argocd-app-backend.yaml` already tracks the `default` namespace. No changes are needed — ArgoCD will display the Rollout status automatically.

```bash
# Verify ArgoCD sees the Rollout
kubectl get application coverline-backend -n argocd -o jsonpath='{.status.health.status}'
```

### Enable the Argo Rollouts UI in ArgoCD (optional)

ArgoCD's UI shows a dedicated rollout panel when the Rollouts controller is installed:

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

Open `https://localhost:8080` → select the `coverline-backend` application → the deployment panel shows canary steps and analysis status.

### GitOps flow with progressive delivery

The full deployment flow is now:

```
Developer pushes image tag change to Git
        ↓
ArgoCD detects diff → syncs Helm chart
        ↓
Argo Rollouts starts canary (10%)
        ↓
AnalysisTemplate queries Prometheus every 30s
        ↓
Green metrics → promote to 30% → 100%
Bad metrics  → automatic rollback → Slack/PagerDuty alert
```

No human intervention required unless the analysis fails — in which case the rollback already happened.

---

## Step 7 — Verify & Screenshot

```bash
# Final state
kubectl argo rollouts get rollout coverline-backend
kubectl get analysistemplate
kubectl get analysisrun

# Rollout history
kubectl argo rollouts history coverline-backend
```

Take screenshots for the README:
- `canary-promoting.png` — rollout mid-promotion showing 30% canary weight
- `rollback-fired.png` — AnalysisRun showing the failed metric and rollback message
- `argocd-rollout.png` — ArgoCD UI showing the Rollout panel

---

## Troubleshooting

### Rollout stuck at 0% weight

**Cause:** The AnalysisTemplate references a Prometheus service that isn't reachable.

```bash
kubectl describe analysisrun <name>
# Look for: "unable to query prometheus"
kubectl get svc -n monitoring | grep prometheus
```

The Prometheus URL in the AnalysisTemplate must match the in-cluster service name. Default: `http://kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090`

### `kubectl argo rollouts` command not found

**Cause:** The kubectl plugin is not installed or not in PATH.

```bash
brew install argoproj/tap/kubectl-argo-rollouts
# or download the binary manually:
# https://github.com/argoproj/argo-rollouts/releases
```

### Rollout shows `Degraded` after applying rollout.yaml

**Cause:** The old Deployment's ReplicaSet still exists and conflicts with the Rollout.

```bash
kubectl get replicaset -l app.kubernetes.io/name=backend
kubectl delete replicaset <old-rs-name>
```

### ArgoCD shows the application as `OutOfSync` after switching to Rollout

**Cause:** The Deployment resource still exists in ArgoCD's state. Delete it and let ArgoCD reconcile.

```bash
kubectl delete deployment coverline-backend
# ArgoCD will re-apply the Rollout from Git on next sync
```

---

## Production Considerations

### 1. Use a service mesh for precise traffic splitting
This lab uses Argo Rollouts' default traffic splitting (pod-count-based weight approximation). In production, integrate with a service mesh (Istio, Linkerd) or an ingress controller (NGINX, Traefik) for exact percentage-based traffic splitting at the L7 layer — critical when you have only a small number of replicas.

### 2. Define multiple metrics in the AnalysisTemplate
This lab gates on HTTP success rate only. In production, combine multiple metrics: success rate + p99 latency + error count. A release that keeps 200 OK but adds 800ms to every request should also trigger a rollback.

### 3. Set `progressDeadlineSeconds`
Without a deadline, a stalled canary (e.g., analysis waiting indefinitely) blocks traffic at the canary weight forever. Set `progressDeadlineSeconds: 600` — if the rollout hasn't completed in 10 minutes, it's automatically aborted.

### 4. Notify on rollback
An automatic rollback is silent by default. Configure Argo Rollouts notifications (or ArgoCD notifications) to alert Slack/PagerDuty whenever a rollback fires — the on-call engineer needs to know a bad deploy was caught and reverted, even if no users were affected.

### 5. Keep the stable version pinned in Git
The GitOps source of truth should always reflect the current stable image tag. After a successful rollout, update the image tag in Git — don't rely solely on `kubectl argo rollouts set image`, which bypasses Git and creates drift.

---

[📝 Take the Phase 5b quiz](https://wb-platform-engineering-lab.github.io/platform-engineering-lab-gke/phase-5b-progressive-delivery/quiz.html)
