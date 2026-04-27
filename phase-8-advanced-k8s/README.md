# Phase 8 — Advanced Kubernetes

> **Kubernetes concepts introduced:** HPA, Cluster Autoscaler, PodDisruptionBudget, resource requests/limits | **Builds on:** Phase 7 observability cluster

[▶ Watch the incident animation](https://wb-platform-engineering-lab.github.io/platform-engineering-lab-gke/phase-8-advanced-k8s/incident-animation.html) · [📝 Take the quiz](https://wb-platform-engineering-lab.github.io/platform-engineering-lab-gke/phase-8-advanced-k8s/quiz.html)

---

## Concepts introduced

| Concept | What it does | Why we need it |
|---|---|---|
| **Resource requests** | Tells the scheduler how much CPU/memory a pod needs | Without requests, pods are placed blindly — nodes become overcommitted |
| **Resource limits** | Caps how much CPU/memory a pod can consume | A runaway pod cannot starve its neighbours |
| **HPA** | Scales pod replicas based on CPU/memory utilisation | Handles traffic spikes without manual intervention |
| **Cluster Autoscaler** | Adds and removes nodes when pod scheduling fails | HPA can request more pods — the Cluster Autoscaler provides nodes to run them |
| **PodDisruptionBudget** | Guarantees a minimum number of pods during voluntary disruptions | A node drain or upgrade cannot take down the entire Deployment simultaneously |

---

## The problem

> *CoverLine — 250,000 members. November. Open enrollment.*
>
> Every year in November, companies renew their employee benefits. In 72 hours, 40,000 members log in simultaneously to review coverage, update dependents, and submit claims.
>
> At 9:14 AM on the first day, the member portal was returning 504 errors. The claims API had stopped responding. Grafana showed CPU at 100% across all three nodes.
>
> The post-mortem was painful to write:
> - Fixed 3-node configuration. No autoscaling. No way to add capacity under load.
> - The claims service had no CPU limits. One runaway pod consumed all CPU on node 2, starving the frontend and the database proxy.
> - No PodDisruptionBudget. A routine node upgrade during the incident window took down 2 of 3 backend pods simultaneously.
> - A node was added manually at 9:47 AM. It took 4 minutes to provision. The incident lasted 45 minutes.
>
> Three enterprise clients called account management. One threatened to leave.
>
> *"I don't want to hear about open enrollment from a client again."*

The decision: make the cluster elastic. Resource limits prevent starvation. HPA handles traffic spikes. Cluster Autoscaler provides nodes. PDBs prevent maintenance from turning into an outage.

---

## Architecture

```
Traffic spike (open enrollment)
    │
    └── CPU rises on coverline-backend pods
            │
            └── HPA detects CPU > 50% (checked every 15s)
                    └── Scales from 2 → 8 pods (max 2 new pods per 30s)
                            │
                            └── New pods → Pending (no capacity on existing nodes)
                                    │
                                    └── Cluster Autoscaler detects unschedulable pods
                                            └── Provisions new GKE node (~3-4 min)
                                                    └── Pods become Running

PodDisruptionBudget in parallel:
    └── Node drain (upgrade, spot preemption)
            └── K8s checks PDB before evicting each pod
                    └── minAvailable: 2 backend pods → drain blocked if only 2 remain
                            └── Upgrade waits — never drops below minimum availability

Scale-down (after traffic subsides):
    └── HPA detects low CPU for 5 min (stabilizationWindow: 300s)
            └── Removes 1 pod per minute (scale-down policy)
                    └── Cluster Autoscaler removes idle nodes after 10 min
```

---

## Repository structure

```
phase-8-advanced-k8s/
├── hpa.yaml    ← HPA for backend (2–8 pods, 50% CPU) and frontend (1–4 pods, 60% CPU)
└── pdb.yaml    ← PDB: backend minAvailable 2, frontend minAvailable 1
```

Resource requests and limits live in `phase-4-helm/charts/backend/values.yaml` and are applied via Helm.

---

## Prerequisites

Cluster running with bootstrap:

```bash
bash bootstrap.sh --phase 8
```

Verify the metrics API is available (required by HPA):

```bash
kubectl get apiservice v1beta1.metrics.k8s.io
kubectl top pods
```

> If `kubectl top pods` returns an error, wait 2 minutes — GKE's metrics aggregation API takes a moment after cluster creation.

Install k6 for the load test:

```bash
brew install k6
```

---

## Architecture Decision Records

- `docs/decisions/adr-031-hpa-cpu-target-50pct.md` — Why 50% CPU target for the backend HPA rather than a higher threshold
- `docs/decisions/adr-032-pdb-minavailable-over-maxunavailable.md` — Why `minAvailable` over `maxUnavailable` for disruption budgets
- `docs/decisions/adr-033-cluster-autoscaler-over-fixed-nodes.md` — Why Cluster Autoscaler over a fixed node count sized for peak load

---

## Challenge 1 — Set resource requests and limits

Resource requests and limits are already defined in `phase-4-helm/charts/backend/values.yaml`. This challenge verifies they are correctly applied and explains why each value was chosen.

### Step 1: Review the backend values

```yaml
# phase-4-helm/charts/backend/values.yaml
resources:
  requests:
    cpu: "100m"     # 0.1 vCPU guaranteed — enough for a healthy idle pod
    memory: "128Mi"
  limits:
    cpu: "500m"     # max 0.5 vCPU — cannot starve neighbours
    memory: "256Mi"
```

| Value | Why |
|---|---|
| `requests.cpu: 100m` | HPA calculates utilisation as `usage / request`. Without a request, HPA cannot compute a percentage |
| `limits.cpu: 500m` | Caps a runaway pod at 0.5 vCPU — the open enrollment incident was caused by a pod with no limit |
| `limits.memory: 256Mi` | If the app exceeds this, the pod is OOMKilled rather than taking down the node |

### Step 2: Apply and verify

```bash
helm upgrade coverline phase-4-helm/charts/backend/
kubectl describe pod -l app.kubernetes.io/name=backend | grep -A6 "Limits\|Requests"
```

### Step 3: Observe real-time resource usage

```bash
kubectl top pods
kubectl top nodes
```

---

## Challenge 2 — Deploy the Horizontal Pod Autoscaler

### Step 1: Review `hpa.yaml`

```yaml
# Backend HPA
spec:
  scaleTargetRef:
    kind: Deployment
    name: coverline-backend
  minReplicas: 2
  maxReplicas: 8
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 50     # scale out when average CPU > 50%
    - type: Resource
      resource:
        name: memory
        target:
          type: Utilization
          averageUtilization: 70
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 30    # react quickly to spikes
      policies:
        - type: Pods
          value: 2
          periodSeconds: 30             # add up to 2 pods every 30s
    scaleDown:
      stabilizationWindowSeconds: 300   # wait 5min before scaling down
      policies:
        - type: Pods
          value: 1
          periodSeconds: 60             # remove 1 pod per minute
```

The asymmetric behaviour is intentional: scale up fast (traffic is already hurting users), scale down slowly (avoid flapping and unnecessary pod churn).

### Step 2: Apply

```bash
kubectl apply -f phase-8-advanced-k8s/hpa.yaml
```

### Step 3: Verify

```bash
kubectl get hpa -w
```

Expected once metrics are flowing (may show `<unknown>` for ~60s):
```
NAME                REFERENCE                      TARGETS         MINPODS   MAXPODS   REPLICAS
coverline-backend   Deployment/coverline-backend   3%/50%, 8%/70%  2         8         2
coverline-frontend  Deployment/coverline-frontend  2%/60%          1         4         1
```

> If TARGETS shows `<unknown>` after 2 minutes, verify resource requests are set on the Deployment — HPA requires them to calculate utilisation.

---

## Challenge 3 — Enable Cluster Autoscaler

HPA adds pods. When nodes run out of capacity, new pods stay `Pending` until the Cluster Autoscaler provisions a new node.

### Step 1: Verify autoscaling is enabled on the node pool

```bash
gcloud container node-pools describe platform-eng-lab-will-dev-gke-np \
  --cluster=platform-eng-lab-will-dev-gke \
  --region=us-central1 \
  --project=platform-eng-lab-will \
  --format="table(autoscaling.enabled, autoscaling.minNodeCount, autoscaling.maxNodeCount)"
```

Expected:
```
ENABLED  MIN_NODE_COUNT  MAX_NODE_COUNT
True     1               3
```

If autoscaling is not enabled, update the Terraform variable `max_node_count` to `3` and apply:

```bash
cd phase-1-terraform/envs/dev
terraform apply -var-file=dev.tfvars
```

### Step 2: Watch nodes during the load test (Challenge 5)

```bash
kubectl get nodes -w
```

When HPA requests more pods than the current nodes can accommodate, the Cluster Autoscaler adds a node. This takes 3–4 minutes on GKE with spot instances.

---

## Challenge 4 — Apply Pod Disruption Budgets

### Step 1: Review `pdb.yaml`

```yaml
# Backend: never drop below 2 pods during voluntary disruptions
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: coverline-backend
spec:
  minAvailable: 2
  selector:
    matchLabels:
      app.kubernetes.io/name: backend

---
# Frontend: at least 1 pod must remain available
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: coverline-frontend
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: frontend
```

### Step 2: Apply

```bash
kubectl apply -f phase-8-advanced-k8s/pdb.yaml
kubectl get pdb
```

Expected:
```
NAME                MIN AVAILABLE   ALLOWED DISRUPTIONS
coverline-backend   2               0
coverline-frontend  1               0
```

`ALLOWED DISRUPTIONS: 0` means with exactly 2 replicas running, no pod can be voluntarily evicted — a drain must wait for HPA to scale up first.

### Step 3: Test — attempt to drain a node

```bash
# Find a node running backend pods
kubectl get pods -o wide | grep backend

# Try to drain it
kubectl drain <node-name> --ignore-daemonsets --delete-emptydir-data
```

Expected: `eviction.k8s.io "coverline-backend-xxx" is forbidden: cannot evict pod as it would violate the pod's disruption budget`

```bash
kubectl uncordon <node-name>
```

This is exactly the protection that was missing during the open enrollment incident.

---

## Challenge 5 — Load test: simulate open enrollment

### Step 1: Port-forward the backend

```bash
kubectl port-forward svc/coverline-backend 5000:5000 &
```

### Step 2: Run the load test

```bash
k6 run phase-8-advanced-k8s/load-test.js
```

### Step 3: Watch the cluster respond in real time (separate terminals)

```bash
# Terminal 1 — watch pods scale
kubectl get hpa coverline-backend -w

# Terminal 2 — watch nodes scale
kubectl get nodes -w

# Terminal 3 — watch resource usage
watch kubectl top pods
```

Expected sequence:

| Time | What happens |
|------|-------------|
| 0–30s | Traffic ramps up, CPU rises above 50% |
| ~45s | HPA triggers scale-out — 2 new pods requested |
| ~60s | If nodes are full, pods stay `Pending` |
| ~4min | Cluster Autoscaler provisions a new node — pods become `Running` |
| After test | HPA scales back to 2 replicas after 5min cooldown |

### Step 4: Check HPA scale events

```bash
kubectl describe hpa coverline-backend | grep -A20 "Events"
```

---

## Challenge 6 — Upgrade the node pool

A GKE node pool upgrade is the most common voluntary disruption in production. GKE drains each node, evicts pods, replaces it with a node running the newer Kubernetes version, and repeats across the pool. Without a PDB, an upgrade can evict all replicas of a deployment simultaneously. This challenge completes the PDB story from Challenge 4 — not by simulating a drain, but by running a real upgrade.

### Step 1: Check the current node pool version

```bash
gcloud container node-pools describe platform-eng-lab-will-dev-gke-np \
  --cluster=platform-eng-lab-will-dev-gke \
  --region=us-central1 \
  --project=platform-eng-lab-will \
  --format="table(version)"
```

### Step 2: Scale the backend to 3 replicas before upgrading

With exactly 2 replicas, the PDB has `ALLOWED DISRUPTIONS: 0` — GKE cannot evict any pod and the upgrade stalls. Scale up first so the PDB allows 1 disruption:

```bash
kubectl scale deployment coverline-backend --replicas=3
kubectl get pdb
```

Expected: `coverline-backend` now shows `ALLOWED DISRUPTIONS: 1`.

### Step 3: Trigger the node pool upgrade

```bash
gcloud container clusters upgrade platform-eng-lab-will-dev-gke \
  --node-pool=platform-eng-lab-will-dev-gke-np \
  --region=us-central1 \
  --project=platform-eng-lab-will
```

GKE shows the target version and prompts for confirmation. The upgrade process per node:
1. Cordon — marks the node unschedulable
2. Drain — evicts pods, checking the PDB before each eviction
3. Delete — removes the old node VM
4. Provision — brings up a new node running the upgraded version
5. Repeat for the next node

### Step 4: Watch the rolling replacement

```bash
# Terminal 1 — nodes cycle through SchedulingDisabled → NotReady → Ready
kubectl get nodes -w

# Terminal 2 — backend pods must stay running throughout
kubectl get pods -l app.kubernetes.io/name=backend -w
```

Expected: nodes appear one at a time with `SchedulingDisabled` status while draining, then `NotReady` briefly, then `Ready` on the new version. Backend pods are never all evicted simultaneously — the PDB enforces `minAvailable: 2` for the entire duration of the upgrade.

If the PDB would be violated (fewer than 2 pods would remain available), GKE pauses the drain and waits rather than proceeding. You can see this pause in the node events:

```bash
kubectl describe node <node-name> | grep -A5 "Events"
```

Look for: `eviction.k8s.io "coverline-backend-xxx" is forbidden: cannot evict pod as it would violate the pod's disruption budget`

### Step 5: Verify the upgrade completed

```bash
gcloud container node-pools describe platform-eng-lab-will-dev-gke-np \
  --cluster=platform-eng-lab-will-dev-gke \
  --region=us-central1 \
  --project=platform-eng-lab-will \
  --format="table(version)"

kubectl get nodes -o wide
```

All nodes should report the new version. Scale the backend back to 2 replicas:

```bash
kubectl scale deployment coverline-backend --replicas=2
```

---

## Teardown

```bash
kubectl delete -f phase-8-advanced-k8s/
```

The cluster and node pool remain. Scale the node pool back to 1 node if the Cluster Autoscaler added nodes during the test:

```bash
gcloud container clusters resize platform-eng-lab-will-dev-gke \
  --node-pool=platform-eng-lab-will-dev-gke-np \
  --num-nodes=1 \
  --region=us-central1
```

---

## Cost breakdown

| Resource | $/day |
|---|---|
| GKE cluster base (Phase 1) | ~$0.66 |
| Additional nodes (Cluster Autoscaler) | ~$0.50/node/day |
| **Phase 8 base cost** | **~$0.66** |

> During a load test with Cluster Autoscaler adding a second node, cost reaches ~$1.16/day. Nodes scale back down automatically after traffic subsides.

---

## Kubernetes concept: the autoscaling chain

HPA and Cluster Autoscaler work at different layers and compose together:

```
Load increases
    → HPA: "I need more pods" (seconds)
        → Scheduler: "No room on existing nodes" → pods Pending
            → Cluster Autoscaler: "Unschedulable pods — add a node" (minutes)
                → Node joins cluster → pods scheduled → Running
```

Neither component knows about the other. HPA only talks to the Deployments API. Cluster Autoscaler only watches for unschedulable pods. The composition is emergent — the cluster self-heals without any orchestration logic.

PDBs operate in the opposite direction: they constrain what Kubernetes can remove. The scheduler respects a PDB before evicting a pod during a drain. If eviction would violate the budget, the drain waits. This is a guarantee, not a best-effort behaviour.

---

## Production considerations

### 1. Set requests based on measured usage, not guesses
Set `requests` at the p50 of actual CPU/memory usage (from Prometheus), and `limits` at 2–3× the p99. Under-requesting causes scheduling failures; over-requesting wastes capacity.

### 2. Use VPA alongside HPA for right-sizing
The Vertical Pod Autoscaler (VPA) automatically adjusts resource requests based on observed usage. Run it in recommendation mode first — it shows what requests should be without actually changing anything.

### 3. Configure `topologySpreadConstraints` for multi-zone clusters
This lab runs in a single zone. In production, use `topologySpreadConstraints` to spread pods across zones — a single zone failure cannot take down the entire Deployment.

### 4. Size PDBs relative to replica count
`minAvailable: 2` is appropriate when running 4+ replicas. With only 2 replicas, `ALLOWED DISRUPTIONS: 0` blocks all maintenance. Use `maxUnavailable: 1` instead — it adapts to the current replica count dynamically.

### 5. Set `--scale-down-utilization-threshold` on Cluster Autoscaler
By default the Cluster Autoscaler removes nodes only when utilisation drops below 50%. In cost-sensitive environments, tune this threshold down — but not so low that it triggers unnecessary scale-down during brief quiet periods.

---

## Outcome

The cluster now handles traffic elastically. A traffic spike scales pods in seconds and nodes in minutes. A runaway pod cannot starve its neighbours. A node drain respects the minimum pod budget. The open enrollment incident — 45 minutes of degraded service caused by a fixed-size cluster with no limits — cannot happen again.

---

[Back to main README](../README.md) | [Next: Phase 9 — Data Platform](../phase-9-data-platform/README.md)
