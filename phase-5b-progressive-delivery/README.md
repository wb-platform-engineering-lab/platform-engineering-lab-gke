# Phase 5b — Progressive Delivery (Argo Rollouts)

> **Progressive delivery concepts introduced:** Rollout, Canary strategy, AnalysisTemplate, AnalysisRun, automatic rollback | **Builds on:** Phase 5 GitOps with ArgoCD

[▶ Watch the incident animation](https://wb-platform-engineering-lab.github.io/platform-engineering-lab-gke/phase-5b-progressive-delivery/incident-animation.html) · [📝 Take the quiz](https://wb-platform-engineering-lab.github.io/platform-engineering-lab-gke/phase-5b-progressive-delivery/quiz.html)

---

## Concepts introduced

| Concept | What it does | Why we need it |
|---|---|---|
| **Rollout** | Argo Rollouts CRD that replaces a Kubernetes Deployment | Adds progressive delivery strategies (canary, blue-green) to any workload |
| **Canary strategy** | Shifts traffic incrementally — 10% → 30% → 100% | A bad release reaches at most 10% of members before being caught |
| **AnalysisTemplate** | Defines a Prometheus query and pass/fail conditions | Gates promotion on live production metrics — not just pod readiness |
| **AnalysisRun** | An execution of an AnalysisTemplate at a specific canary step | Records the exact metric values that caused a promotion or rollback |
| **Automatic rollback** | Fires when an AnalysisRun fails | Traffic shifts back to stable immediately — no human intervention required |

---

## The problem

> *CoverLine — 20,000 members. A Thursday afternoon.*
>
> The backend team shipped a new claims processing feature at 2:30 PM. ArgoCD synced the Helm chart in 45 seconds. The Deployment rolled out to 100% of pods in under 3 minutes. Everything looked green.
>
> At 2:48 PM, the error rate on the Grafana dashboard had climbed from 0.2% to 12.4%. The new release had a silent regression in the claims submission endpoint — it failed for any member with more than 5 dependents. Roughly 8% of the member base.
>
> The team rolled back at 3:06 PM. 18 minutes of degraded service. 1,600 members affected. Two enterprise client success managers received escalation emails before the engineers knew there was a problem.
>
> *"Why did 100% of traffic hit the new version before we verified it worked?"*

The decision: progressive delivery. Ship to 10% of traffic, query Prometheus for 2 minutes, advance only if metrics are healthy. If anything looks wrong, roll back automatically — before the team has time to notice.

---

## Architecture

```
Merge to main
    │
    ├── CD pipeline (Phase 4)
    │       └── Builds image → updates values.yaml → commits to Git
    │
    └── ArgoCD (Phase 5)
            └── Detects values.yaml change → syncs chart
                    │
                    └── Argo Rollouts intercepts
                            ├── Step 1: setWeight 10%  → 1 canary pod
                            ├── Step 2: pause 2 minutes
                            ├── Step 3: AnalysisRun → query Prometheus (pod readiness)
                            │       ├── pass  → setWeight 30%
                            │       └── fail  → rollback to stable immediately
                            ├── Step 4: pause 2 minutes
                            ├── Step 5: AnalysisRun → query Prometheus again
                            │       ├── pass  → setWeight 100% → rollout complete
                            │       └── fail  → rollback to stable immediately
                            └── stable pointer updated

AnalysisTemplate: coverline-success-rate
    └── Queries kube_pod_status_ready every 30s (3 checks)
    └── Fails if any canary pod is not ready (failureLimit: 0)
```

---

## Repository structure

```
phase-5b-progressive-delivery/
├── rollout.yaml             ← Rollout replacing the backend Deployment
│                              strategy: canary, steps: 10% → 30% → 100%
└── analysis-template.yaml  ← AnalysisTemplate querying Prometheus pod readiness
```

---

## Prerequisites

Cluster running with Phase 5 (ArgoCD + coverline-backend deployed) and Phase 6 (Prometheus running in the `monitoring` namespace — required by the AnalysisTemplate):

```bash
kubectl get applications -n argocd
kubectl get pods -n monitoring | grep prometheus
```

Install the Argo Rollouts kubectl plugin:

```bash
brew install argoproj/tap/kubectl-argo-rollouts
kubectl argo rollouts version
```

---

## Architecture Decision Records

- `docs/decisions/adr-021-canary-over-bluegreen.md` — Why canary over blue-green for progressive delivery at CoverLine's scale
- `docs/decisions/adr-022-pod-readiness-gate.md` — Why pod readiness as the initial AnalysisTemplate gate before HTTP metrics are available
- `docs/decisions/adr-023-rollout-outside-helm.md` — Why the Rollout is applied as a standalone manifest rather than replacing the Helm chart Deployment

---

## Challenge 1 — Install Argo Rollouts

### Step 1: Create the namespace and apply the controller

```bash
kubectl create namespace argo-rollouts
kubectl apply -n argo-rollouts \
  -f https://github.com/argoproj/argo-rollouts/releases/latest/download/install.yaml
```

### Step 2: Wait for the controller to be ready

```bash
kubectl get pods -n argo-rollouts -w
```

Expected:
```
NAME                             READY   STATUS    RESTARTS
argo-rollouts-xxxx               1/1     Running   0
```

---

## Challenge 2 — Apply the AnalysisTemplate and Rollout

The AnalysisTemplate must exist before the Rollout starts. If it is missing when the first canary step runs, the AnalysisRun immediately degrades.

### Step 1: Review the AnalysisTemplate

```yaml
# analysis-template.yaml
spec:
  metrics:
    - name: pod-readiness
      interval: 30s
      count: 3
      failureLimit: 0
      provider:
        prometheus:
          address: http://kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090
          query: |
            min(
              kube_pod_status_ready{
                namespace="default",
                pod=~"coverline-backend.*",
                condition="true"
              }
            )
      successCondition: result[0] >= 1
      failureCondition: result[0] < 1
```

The query checks every 30 seconds, 3 times (`count: 3`). If a single check finds any canary pod not ready, the analysis fails immediately (`failureLimit: 0`) and the rollback fires.

### Step 2: Review the Rollout strategy

```yaml
# rollout.yaml (strategy section)
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
    antiAffinity:
      preferredDuringSchedulingIgnoredDuringExecution:
        weight: 1
```

`antiAffinity` ensures canary and stable pods land on different nodes where possible — a node failure cannot take both versions down simultaneously.

### Step 3: Apply the AnalysisTemplate first, then replace the Deployment

```bash
# Apply the AnalysisTemplate first
kubectl apply -f phase-5b-progressive-delivery/analysis-template.yaml

# Remove the existing Deployment (the Rollout will manage pods instead)
kubectl delete deployment coverline-backend

# Apply the Rollout
kubectl apply -f phase-5b-progressive-delivery/rollout.yaml
```

### Step 4: Verify the Rollout is healthy

```bash
kubectl argo rollouts get rollout coverline-backend --watch
```

Expected:
```
Name:            coverline-backend
Status:          ✔ Healthy
Strategy:        Canary
  Step:          6/6
  SetWeight:     100
  ActualWeight:  100
Replicas:
  Desired:       2   Current: 2   Updated: 2   Ready: 2
```

---

## Challenge 3 — Deploy a new version (green path)

Simulate shipping a new release and watch the canary promote automatically.

### Step 1: Trigger a canary rollout

```bash
kubectl argo rollouts set image coverline-backend \
  backend=us-central1-docker.pkg.dev/platform-eng-lab-will/coverline/backend:latest
```

### Step 2: Watch the rollout progress

```bash
kubectl argo rollouts get rollout coverline-backend --watch
```

| Time | What happens |
|------|-------------|
| 0s | 1 canary pod created — 10% weight |
| ~10s | AnalysisRun starts — Prometheus queried every 30s |
| 2m | Analysis passes (3/3 checks) — weight advances to 30% |
| 4m | Analysis passes again — weight advances to 100% |
| ~5m | Old pods terminated — rollout complete |

### Step 3: Inspect the AnalysisRun

```bash
kubectl get analysisrun
kubectl describe analysisrun <name>
```

The AnalysisRun log shows the exact Prometheus query result at each measurement interval — a permanent audit trail of why the canary was promoted.

---

## Challenge 4 — Simulate a bad deploy (automatic rollback)

Reproduce the Thursday afternoon incident: ship a broken version and watch it get caught at 10%.

### Step 1: Deploy a broken image

```bash
kubectl argo rollouts set image coverline-backend \
  backend=us-central1-docker.pkg.dev/platform-eng-lab-will/coverline/backend:broken-image

kubectl argo rollouts get rollout coverline-backend --watch
```

The canary pod enters `ImagePullBackOff`. Argo Rollouts stalls at step 0 — it waits for the canary pod to become ready before starting the pause timer.

### Step 2: Abort and roll back

```bash
kubectl argo rollouts abort coverline-backend
kubectl argo rollouts undo coverline-backend
```

`undo` creates a new revision with the previous stable image and runs it through the canary steps. To skip directly to stable:

```bash
kubectl argo rollouts promote coverline-backend --full
```

### Step 3: Verify the stable version is restored

```bash
kubectl argo rollouts get rollout coverline-backend
# Status: ✔ Healthy
```

---

## Challenge 5 — Verify ArgoCD integration

ArgoCD recognises `Rollout` resources and reflects their health in the application status.

### Step 1: Check the ArgoCD application health

```bash
kubectl get application coverline-backend -n argocd \
  -o jsonpath='{.status.health.status}'
```

Expected: `Healthy`

### Step 2: Trigger a sync via Git

Update the image tag in `phase-3-helm/charts/backend/values.yaml`, push to main, and watch the full GitOps + progressive delivery loop:

```
Git push → ArgoCD syncs chart → Argo Rollouts starts canary → AnalysisRun passes → 100%
```

---

## Teardown

```bash
kubectl delete -f phase-5b-progressive-delivery/
kubectl delete namespace argo-rollouts
# Restore the standard Deployment for subsequent phases
kubectl apply -f phase-2-kubernetes/backend/deployment.yaml
```

---

## Cost breakdown

Argo Rollouts runs as a single controller pod on the existing cluster. No additional GCP resources are created.

| Resource | $/day |
|---|---|
| GKE cluster (Phase 1) | ~$0.66 |
| Argo Rollouts controller | included in node cost |
| **Phase 5b additional cost** | **$0** |

---

## Progressive delivery concept: canary vs. rolling update

A Kubernetes rolling update replaces pods one by one until all replicas run the new version. It stops if pods fail readiness checks — but by then, the new version is already serving a fraction of traffic.

A canary rollout is different in two ways:

1. **Traffic weight is explicit.** You control exactly what percentage of requests goes to the new version at each step — not just how many pods are running it.
2. **Promotion is gated on metrics.** The rollout only advances when an external signal (Prometheus) confirms the new version is healthy. A deployment that passes pod readiness but causes silent errors (wrong API format, business logic regression) will fail the analysis and roll back.

The Thursday afternoon incident would not have happened: 1,600 members would have been 160 (10% canary weight), and the error spike at 2:48 PM would have failed the first AnalysisRun, triggering a rollback at 2:52 PM — before the enterprise client escalations.

---

## Production considerations

### 1. Gate on HTTP success rate, not just pod readiness
The AnalysisTemplate in this lab uses pod readiness as the gate — reliable for any app, but blind to silent regressions like wrong response formats. In production, instrument the app with `prometheus-flask-exporter` and gate on HTTP success rate ≥ 99% and p99 latency ≤ 500ms.

### 2. Set `progressDeadlineSeconds`
Without a deadline, a stalled canary blocks traffic at 10% indefinitely. Set `progressDeadlineSeconds: 600` — the rollout is automatically aborted if it has not progressed within 10 minutes.

### 3. Notify on automatic rollback
A rollback is silent by default. Configure Argo Rollouts notifications (or ArgoCD notifications) to alert Slack or PagerDuty when a rollback fires — the on-call engineer needs to know, even if no users were affected.

### 4. Move the Rollout into the Helm chart
This lab applies `rollout.yaml` as a standalone manifest. When ArgoCD also manages the Helm chart (which contains a Deployment), both will try to own the same pods. In production, replace `deployment.yaml` in the Helm chart with a `rollout.yaml` template so ArgoCD manages a single object.

### 5. Use a service mesh for exact traffic splitting
This lab uses pod-count-based weight approximation — with 2 replicas, 10% weight means 1 pod out of 10 (requires 10 total pods). A service mesh (Istio, Linkerd) or NGINX ingress provides exact percentage-based L7 traffic splitting regardless of replica count.

---

## Outcome

A bad deploy can no longer silently reach 100% of members. Every new backend image goes through a 10% → 30% → 100% canary with Prometheus-gated promotion. An unhealthy canary rolls back automatically within 2 minutes — before alerts fire and before users notice.

---

[Back to main README](../README.md) | [Next: Phase 6 — Observability](../phase-6-observability/README.md)
