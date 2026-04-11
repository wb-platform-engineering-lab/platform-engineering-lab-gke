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
# Apply the AnalysisTemplate FIRST — if the Rollout starts without it, the first canary will immediately degrade
kubectl apply -f phase-5b-progressive-delivery/analysis-template.yaml

# Remove the existing Deployment
kubectl delete deployment coverline-backend

# Apply the Rollout
kubectl apply -f phase-5b-progressive-delivery/rollout.yaml
```

> **Note:** If you apply the Rollout without deleting the Deployment first, Argo Rollouts will scale the Deployment down to 0 automatically and take over. Either approach works, but deleting first is cleaner.

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

## Step 3 — Verify the AnalysisTemplate is applied

The AnalysisTemplate was already applied in Step 2. Confirm it is present before proceeding — if it is missing, the first canary will degrade immediately with `AnalysisTemplate not found`.

```bash
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

The template queries `kube_pod_status_ready{condition="true"}` from kube-state-metrics — a metric that is always present for any running pod, with no app instrumentation required. It checks that all canary pods are in a ready state. If any canary pod becomes unready (crash, OOM, failed readiness probe), the analysis fails and the rollback fires.

> **Note:** In production with a properly instrumented app, combine multiple metrics in the AnalysisTemplate. Here is a complete example gating on both HTTP success rate and p99 latency:
>
> ```yaml
> apiVersion: argoproj.io/v1alpha1
> kind: AnalysisTemplate
> metadata:
>   name: coverline-success-rate
>   namespace: default
> spec:
>   metrics:
>     - name: success-rate
>       interval: 30s
>       failureLimit: 1
>       provider:
>         prometheus:
>           address: http://kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090
>           query: |
>             sum(rate(http_requests_total{namespace="default",job="coverline-backend",status!~"5.."}[2m]))
>             /
>             sum(rate(http_requests_total{namespace="default",job="coverline-backend"}[2m]))
>       successCondition: result[0] >= 0.99
>       failureCondition: result[0] < 0.99
>
>     - name: p99-latency
>       interval: 30s
>       failureLimit: 1
>       provider:
>         prometheus:
>           address: http://kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090
>           query: |
>             histogram_quantile(0.99,
>               sum(rate(http_request_duration_seconds_bucket{namespace="default",job="coverline-backend"}[2m]))
>               by (le)
>             )
>       successCondition: result[0] <= 0.5
>       failureCondition: result[0] > 0.5
> ```
>
> This gates promotion on **both**: HTTP success rate ≥ 99% AND p99 latency ≤ 500ms. Either metric failing independently triggers a rollback — a release that returns 200 OK but adds 800ms to every request is caught just as a 5xx spike would be.
>
> Both metrics require the app to expose a `/metrics` endpoint (e.g. via `prometheus-flask-exporter` for Python). The `kube_pod_status_ready` gate used in this lab is a reliable baseline for any app regardless of instrumentation.

---

## Step 4 — Deploy a new version (green path)

Simulate shipping a new release by updating the image tag. This triggers the canary rollout.

```bash
kubectl argo rollouts set image coverline-backend \
  backend=us-central1-docker.pkg.dev/platform-eng-lab-will/coverline/backend:latest

kubectl argo rollouts get rollout coverline-backend --watch
```

> **Note:** This lab uses `:latest` since it is the only tag guaranteed to exist in the registry. Argo Rollouts still runs all canary steps and analysis regardless of whether the new image differs from stable — the progression logic is driven by the revision change, not image content.

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

Now simulate the Thursday afternoon incident: ship a broken version and watch it get caught before it reaches 100%.

```bash
kubectl argo rollouts set image coverline-backend \
  backend=us-central1-docker.pkg.dev/platform-eng-lab-will/coverline/backend:broken-image

kubectl argo rollouts get rollout coverline-backend --watch
```

The canary pod will enter `ImagePullBackOff` — it can never become ready, so Argo Rollouts stalls at step 0 waiting for it. The 2-minute pause timer doesn't start until the canary pod is available.

> **Why doesn't it auto-abort?** Argo Rollouts waits for the canary pod to become ready before starting the pause timer. A pod stuck in `ImagePullBackOff` will eventually be caught by `progressDeadlineSeconds` (default: 10 minutes). For this lab, abort manually.

```bash
# Trigger the abort
kubectl argo rollouts abort coverline-backend

# Roll back to the previous stable revision
kubectl argo rollouts undo coverline-backend
```

`undo` creates a new revision (e.g. revision 4) with the previous image — it goes through the canary steps again since both canary and stable are now the same image. Let it promote, or skip the steps:

```bash
kubectl argo rollouts promote coverline-backend --full
```

Verify traffic is back on the stable version:
```bash
kubectl argo rollouts get rollout coverline-backend
# Status: ✔ Healthy
```

### Check the AnalysisRuns

```bash
kubectl get analysisrun
kubectl describe analysisrun <name>
```

The AnalysisRun log shows the exact Prometheus query result — the same signal Karim would have seen on Grafana, but acted on automatically.

---

## Step 6 — ArgoCD integration

### Apply the ArgoCD applications

```bash
kubectl apply -f phase-5-gitops/argocd-app-backend.yaml
kubectl apply -f phase-5-gitops/argocd-app-frontend.yaml
kubectl get applications -n argocd
```

Expected:
```
NAME                 SYNC STATUS   HEALTH STATUS
coverline-backend    Synced        Healthy
coverline-frontend   Synced        Healthy
```

### What ArgoCD shows out of the box

ArgoCD recognises `Rollout` resources from the CRDs and reflects their health correctly — `Healthy`, `Progressing`, or `Degraded` — in the sync status. In the UI you will see the Rollout listed as a resource inside the application, and its health status updates in real time as the canary progresses.

**What you will NOT see without the UI extension:** canary weight percentages, step-by-step progress, and AnalysisRun pass/fail details. The standard ArgoCD UI does not include a dedicated rollout panel by default.

### Verify ArgoCD sees the Rollout

```bash
kubectl get application coverline-backend -n argocd \
  -o jsonpath='{.status.health.status}'
# Expected: Healthy
```

### Install the Argo Rollouts UI extension (optional)

To get the full canary panel in ArgoCD showing step progress, weights, and AnalysisRun results, install the Rollouts UI extension. Installation instructions vary by ArgoCD version — refer to the official guide:

> https://github.com/argoproj-labs/rollout-extension

Then port-forward and open the UI:

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

Open `https://localhost:8080` → select `coverline-backend` → the Rollout panel now shows canary steps, weight percentages, and AnalysisRun status.

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

### Canary pod in `ImagePullBackOff` — rollout stalls at step 0

**Cause:** Argo Rollouts waits for the canary pod to become available before starting the pause timer. A pod that can never start (bad image tag, registry auth failure) stalls the rollout indefinitely.

**Fix:** Abort and undo manually:
```bash
kubectl argo rollouts abort coverline-backend
kubectl argo rollouts undo coverline-backend
```

To avoid this blocking in production, set `progressDeadlineSeconds: 300` in the Rollout spec — the rollout is automatically aborted if it hasn't progressed within that window.

---

### Rollout stuck at 0% weight (analysis cannot reach Prometheus)

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

### 6. Move the Rollout into the Helm chart
This lab applies `rollout.yaml` as a standalone manifest outside of Helm. When ArgoCD syncs the Helm chart, it creates a separate Helm-managed Deployment alongside the Rollout — resulting in duplicate pods sharing the same selector.

In production, replace the `Deployment` template in the Helm chart with a `Rollout`:

**`phase-3-helm/charts/backend/templates/rollout.yaml`** (replace `deployment.yaml`):
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: {{ include "backend.fullname" . }}
  labels:
    {{- include "backend.labels" . | nindent 4 }}
spec:
  replicas: {{ .Values.replicaCount }}
  selector:
    matchLabels:
      {{- include "backend.selectorLabels" . | nindent 6 }}
  template:
    metadata:
      labels:
        {{- include "backend.selectorLabels" . | nindent 8 }}
    spec:
      containers:
        - name: backend
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
          ports:
            - containerPort: 5000
          {{- with .Values.resources }}
          resources:
            {{- toYaml . | nindent 12 }}
          {{- end }}
  strategy:
    canary:
      steps:
        - setWeight: 10
        - pause: {duration: 2m}
        - analysis:
            templates:
              - templateName: coverline-success-rate
        - setWeight: 30
        - pause: {duration: 2m}
        - analysis:
            templates:
              - templateName: coverline-success-rate
```

With this in place, ArgoCD manages one object (the Rollout) and there is no Deployment conflict. The AnalysisTemplate can live in a separate `templates/analysis-template.yaml` in the same chart.

---

[📝 Take the Phase 5b quiz](https://wb-platform-engineering-lab.github.io/platform-engineering-lab-gke/phase-5b-progressive-delivery/quiz.html)
