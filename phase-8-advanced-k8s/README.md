# Phase 8 — Advanced Kubernetes

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
kubectl port-forward svc/coverline 5000:5000 &
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


---

[📝 Take the Phase 8 quiz](https://wb-platform-engineering-lab.github.io/platform-engineering-lab-gke/phase-8-advanced-k8s/quiz.html)
