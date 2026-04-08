# Phase 8 — Advanced Kubernetes

[▶ Watch the incident animation](https://wb-platform-engineering-lab.github.io/platform-engineering-lab-gke/phase-8-advanced-k8s/incident-animation.html)

---

> **CoverLine — 250,000 members. November. Open enrollment.**
>
> Every year in November, companies renew their employee benefits. In 72 hours, 40,000 members log in simultaneously to review coverage, update dependents, and submit claims.
>
> At 9:14 AM on the first day, Karim's phone lit up. The member portal was returning 504 errors. The claims API had stopped responding. The Grafana dashboard showed CPU at 100% across all three nodes.
>
> The post-mortem was painful to write:
> - The cluster had a fixed 3-node configuration. No autoscaling. No way to add capacity.
> - The claims service had no CPU limits. One runaway pod had consumed all CPU on node 2, starving the frontend and the database proxy.
> - There was no PodDisruptionBudget. A routine node upgrade during the incident window had taken down 2 of 3 backend pods simultaneously.
> - Karim added a node manually at 9:47 AM. It took 4 minutes to provision. The incident lasted 45 minutes.
>
> Three enterprise clients called account management. One threatened to leave.
>
> *"We need the cluster to handle this automatically,"* Léa said. *"I don't want to hear about open enrollment from a client again."*

> **▶ [Watch the incident unfold →](https://wb-platform-engineering-lab.github.io/platform-engineering-lab-gke/phase-8-advanced-k8s/incident-animation.html)**
> *(animated dashboard — no install required)*

---

## What we'll build

| Component | What it does |
|-----------|-------------|
| **Resource requests & limits** | Prevent a single pod from starving its neighbours |
| **Horizontal Pod Autoscaler (HPA)** | Scale pods automatically based on CPU/memory |
| **Cluster Autoscaler** | Add and remove nodes automatically based on demand |
| **Pod Disruption Budgets (PDB)** | Guarantee a minimum number of pods during node maintenance |
| **Load test** | Simulate open enrollment traffic with `k6` and observe scale-out |

---

## Prerequisites

Cluster running with bootstrap:
```bash
cd phase-1-terraform && terraform apply
gcloud container clusters get-credentials platform-eng-lab-will-gke \
  --region us-central1 --project platform-eng-lab-will
bash bootstrap.sh --phase 8
```

Verify metrics-server is running (required for HPA):
```bash
kubectl get deployment metrics-server -n kube-system
```

> **Note:** GKE includes metrics-server by default. If `kubectl top pods` returns an error, wait 2 minutes after cluster creation.

---

## Step 1 — Resource Requests & Limits

Resource **requests** tell the scheduler how much CPU/memory a pod needs to be placed on a node. Resource **limits** cap how much it can consume — preventing a runaway pod from stealing resources from its neighbours.

### Why this matters

Without limits, one pod with a memory leak can OOM the entire node. Without requests, the scheduler places pods blindly and the node becomes overcommitted.

### Apply to coverline-backend

The backend chart already has resources configured in `phase-3-helm/charts/backend/values.yaml`. Verify they're sensible:

```yaml
resources:
  requests:
    cpu: "100m"     # 0.1 vCPU guaranteed
    memory: "128Mi"
  limits:
    cpu: "500m"     # max 0.5 vCPU — cannot starve neighbours
    memory: "256Mi"
```

Apply and verify:
```bash
helm upgrade coverline phase-3-helm/charts/backend/
kubectl describe pod -l app.kubernetes.io/name=backend | grep -A6 "Limits\|Requests"
```

### Apply to coverline-frontend

```bash
kubectl set resources deployment/coverline-frontend \
  --requests=cpu=50m,memory=64Mi \
  --limits=cpu=200m,memory=128Mi

kubectl describe pod -l app.kubernetes.io/name=frontend | grep -A6 "Limits\|Requests"
```

### Observe resource usage

```bash
kubectl top pods
kubectl top nodes
```

---

## Step 2 — Horizontal Pod Autoscaler (HPA)

HPA watches CPU/memory metrics and automatically scales the number of pod replicas up or down.

### Create HPA for coverline-backend

```bash
kubectl apply -f phase-8-advanced-k8s/hpa.yaml
```

Verify it's reading metrics (may show `<unknown>` for ~60s after creation):
```bash
kubectl get hpa coverline-backend -w
```

Expected output once active:
```
NAME                REFERENCE                      TARGETS   MINPODS   MAXPODS   REPLICAS
coverline-backend   Deployment/coverline-backend   3%/50%    2         8         2
```

> **Common issue:** If TARGETS shows `<unknown>` for more than 2 minutes, verify resource requests are set on the deployment — HPA calculates utilisation as `current usage / request`. Without requests, HPA cannot compute a percentage.

---

## Step 3 — Cluster Autoscaler

HPA adds pods. Cluster Autoscaler adds nodes when pods can't be scheduled due to insufficient capacity.

GKE's Cluster Autoscaler is enabled at the node pool level in Terraform.

### Enable in Terraform

```bash
cd phase-1-terraform
terraform apply -target=module.gke
```

Verify:
```bash
gcloud container node-pools describe platform-eng-lab-will-node-pool \
  --cluster=platform-eng-lab-will-gke \
  --region=us-central1 \
  --project=platform-eng-lab-will \
  | grep -A5 autoscaling
```

### Observe scale-out during load test (Step 4)

```bash
kubectl get nodes -w
```

---

## Step 4 — Pod Disruption Budgets

A PodDisruptionBudget (PDB) tells Kubernetes: *"Never take down more than N pods of this deployment at the same time"* — whether during a node drain, a rolling upgrade, or Cluster Autoscaler scale-down.

This is what would have prevented the open enrollment incident where 2 of 3 backend pods went down simultaneously during a node upgrade.

```bash
kubectl apply -f phase-8-advanced-k8s/pdb.yaml
kubectl get pdb
```

Expected output:
```
NAME                MIN AVAILABLE   MAX UNAVAILABLE   ALLOWED DISRUPTIONS
coverline-backend   2               N/A               0
coverline-frontend  1               N/A               0
```

Test it — try to drain a node and verify Kubernetes respects the budget:
```bash
# Find a node running backend pods
kubectl get pods -o wide | grep backend

# Try to drain it
kubectl drain <node-name> --ignore-daemonsets --delete-emptydir-data

# Should see: "eviction.k8s.io "coverline-backend-xxx" is forbidden: cannot evict pod as it would violate the pod's disruption budget"
kubectl uncordon <node-name>
```

---

## Step 5 — Load Test (Simulate Open Enrollment)

We'll use `k6` to simulate 40,000 concurrent members hitting the claims API, then watch HPA and Cluster Autoscaler respond.

### Install k6

```bash
brew install k6
```

### Run the load test

```bash
kubectl port-forward svc/coverline-backend 5000:5000 &
k6 run phase-8-advanced-k8s/load-test.js
```

### Watch the cluster respond in real time (separate terminal)

```bash
# Watch pods scale up
kubectl get hpa coverline-backend -w

# Watch nodes scale up
kubectl get nodes -w

# Watch resource usage
watch kubectl top pods
```

### Expected behaviour

| Time | What happens |
|------|-------------|
| 0–30s | Traffic ramps up, CPU rises |
| ~45s | HPA detects CPU > 50%, triggers scale-out |
| ~60s | New pods scheduled — if nodes are full, Cluster Autoscaler provisions a new node |
| ~4min | New node joins, pods become Running |
| After test | HPA scales back down after 5 minutes of low CPU (cooldown period) |

---

## Step 6 — Verify & Screenshot

```bash
# Final state
kubectl get hpa
kubectl get pdb
kubectl top pods
kubectl get nodes

# HPA scale events
kubectl describe hpa coverline-backend | grep -A20 "Events"
```

Take screenshots for the README:
- `hpa-scaling.png` — HPA scaling event in action
- `cluster-autoscaler.png` — new node provisioned during load test
- `k6-results.png` — k6 terminal output showing throughput

---

## Production Best Practices

What companies like Shopify, Airbnb, and Delivery Hero actually do — and how it differs from this lab.

---

### 1. Design for Multi-Zone Failure, Not Single-Zone Safety

This lab pinned the node pool to a single zone to avoid PVC affinity issues. **Major companies do the opposite** — they design for full zone failure:

- **Regional clusters** with nodes spread across 3 zones
- **Regional Persistent Disks** that survive a complete zone outage:

```yaml
# StorageClass with regional PD — survives one zone going down
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: regional-pd
provisioner: pd.csi.storage.gke.io
parameters:
  type: pd-balanced
  replication-type: regional-pd
  zones: us-central1-b, us-central1-c
```

- **Topology spread constraints** to force pods across zones:

```yaml
topologySpreadConstraints:
  - maxSkew: 1
    topologyKey: topology.kubernetes.io/zone
    whenUnsatisfiable: DoNotSchedule
    labelSelector:
      matchLabels:
        app: coverline-backend
```

Single-zone pinning avoids the scheduling issue but creates a zone-level single point of failure. Shopify and Airbnb accept the higher regional PD cost because a zone outage taking down the platform is unacceptable.

---

### 2. Use Dedicated Node Pools for Critical Infrastructure

Vault, PostgreSQL, and monitoring are hard dependencies. If they can't schedule, the entire platform breaks.

| Node Pool | Workloads | Autoscaling |
|-----------|-----------|-------------|
| `app-pool` | backend, frontend | min 2, max 10 — autoscaled |
| `infra-pool` | Vault, PostgreSQL, Redis | fixed size — **never autoscaled** |
| `monitoring-pool` | Prometheus, Grafana, Loki | fixed size |

Use taints on infra/monitoring pools and tolerations on their workloads to enforce this. See phase-7 README for the Vault-specific configuration.

---

### 3. Replace CPU-Based HPA With Business Metrics (KEDA)

CPU-based HPA is a lagging indicator — by the time CPU is at 50%, you're already degraded. **Companies like Adobe, Microsoft, and Delivery Hero** scale on business signals instead, using **KEDA** (Kubernetes Event-Driven Autoscaling):

```yaml
# Scale on Kafka queue depth — before CPU shows any pressure
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: coverline-backend
spec:
  scaleTargetRef:
    name: coverline-backend
  triggers:
    - type: kafka
      metadata:
        topic: claims-submitted
        lagThreshold: "100"   # scale when 100+ unprocessed claims
    - type: prometheus
      metadata:
        serverAddress: http://prometheus:9090
        query: rate(http_requests_total{service="backend"}[1m])
        threshold: "500"      # scale when >500 req/s
```

This scales the service before users notice slowness, not after.

---

### 4. Replace Cluster Autoscaler With Karpenter

Most companies at scale (>50 nodes) replace Cluster Autoscaler with **Karpenter** (open source, works on GKE):

| Feature | Cluster Autoscaler | Karpenter |
|---------|-------------------|-----------|
| Node provisioning speed | ~3–5 min | ~30–60s |
| Node sizing | Fixed node pool types | Right-sizes to the pending pod |
| Spot/Preemptible support | Manual configuration | Automatic fallback |
| Used by | Small/mid setups | Anthropic, Figma, Delivery Hero |

Karpenter provisions the exact node size needed for the pending pod instead of adding another clone of an existing node. This avoids over-provisioning and reduces cost by 20–40%.

---

### 5. Run Load Tests Inside the Cluster

`kubectl port-forward` is a debug tool — it drops connections under high concurrency. Run k6 as a Kubernetes Job that hits services directly:

```bash
# Update the base URL in load-test.js first:
# const BASE_URL = 'http://coverline-backend.default.svc.cluster.local:5000';

kubectl run k6 --image=grafana/k6 --rm -it --restart=Never -- \
  run --vus 200 --duration 6m - < phase-8-advanced-k8s/load-test.js
```

For production load testing, companies use dedicated tools outside the cluster being tested: **k6 Cloud**, **Gatling Enterprise**, or a separate k6 cluster — so the load generator doesn't consume resources from the system under test.

---

### 6. Set PodDisruptionBudgets on All Stateful Workloads

PDBs aren't just for application pods. Add them to PostgreSQL, Redis, and Vault too — otherwise a node drain or Cluster Autoscaler scale-down can take down the entire database layer simultaneously:

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: postgresql-pdb
spec:
  maxUnavailable: 0  # never take down the primary
  selector:
    matchLabels:
      app.kubernetes.io/name: postgresql
      app.kubernetes.io/component: primary
```

---

### 7. Protect Stateful Pods From Cluster Autoscaler Eviction

Add this annotation to all StatefulSet pods to prevent Cluster Autoscaler from evicting them during scale-down:

```yaml
annotations:
  cluster-autoscaler.kubernetes.io/safe-to-evict: "false"
```

---

### 8. Use `minReplicas: 2` on All Production HPAs

An HPA with `minReplicas: 1` is a single point of failure — the old pod terminates before the new one is ready during scaling events. Always keep at least 2 replicas in production, combined with a PDB of `minAvailable: 1`.

---

## Troubleshooting

### HPA shows `<unknown>` targets

**Cause:** Resource requests not set on the deployment, or metrics-server not ready.

```bash
kubectl top pods                          # if this fails, metrics-server isn't ready
kubectl get apiservice v1beta1.metrics.k8s.io  # should be "True"
kubectl describe deployment coverline-backend | grep -A4 Requests
```

### Cluster Autoscaler not adding nodes

**Cause:** Autoscaling not enabled on the node pool, or min/max bounds already reached.

```bash
kubectl describe configmap cluster-autoscaler-status -n kube-system
```

### Pods pending after HPA scale-out

**Cause:** All nodes are full and Cluster Autoscaler hasn't provisioned a new one yet — normal, wait ~3 minutes.

```bash
kubectl get events --sort-by='.lastTimestamp' | grep -i "scale\|trigger\|unschedulable"
```

### StatefulSet pods (Redis, PostgreSQL) stuck in Pending after node replacement

**Cause:** PersistentVolumes are provisioned in a specific GCP zone. When the node that hosted the PV is replaced by Cluster Autoscaler in a different zone, the pod can't schedule because no node in the PV's zone is available.

**Symptoms:** `kubectl describe pod <name>` shows:
```
0/N nodes are available: N node(s) didn't match PersistentVolume's node affinity
```

**Fix:** Delete the PVC so a new one is provisioned in the current zone. **Data will be lost** — acceptable for Redis (cache) but back up PostgreSQL first.

```bash
# Check which zone the PV is pinned to
kubectl get pvc <pvc-name> -o jsonpath='{.spec.volumeName}' | \
  xargs kubectl get pv -o jsonpath='{.spec.nodeAffinity}'

# Check which zones current nodes are in
kubectl get nodes -o custom-columns='NAME:.metadata.name,ZONE:.metadata.labels.topology\.kubernetes\.io/zone'

# If zones don't match — delete the PVC (StatefulSet will recreate it)
kubectl delete pvc <pvc-name>
```

**Prevention:** Pin your GKE node pool to a single zone in Terraform to ensure Cluster Autoscaler always replaces nodes in the same zone as your PVs:

```hcl
# In your node pool Terraform config
node_locations = ["us-central1-b"]  # single zone — PVs and nodes always co-located
```

Alternatively, use regional PDs (`pd-balanced` with `replication-type=regional-pd`) for zone-redundant storage — higher cost but survives zone failure.
