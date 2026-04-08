# Phase 2 — Kubernetes Core

[▶ Watch the incident animation](https://wb-platform-engineering-lab.github.io/platform-engineering-lab-gke/phase-2-kubernetes/incident-animation.html)

---

> **CoverLine — 200 members. The logistics client is live.**
>
> The first corporate client went live on a Monday. By Wednesday, they had 200 employee members submitting claims. By Thursday, the backend was struggling.
>
> A developer pushed a config change. The single Docker container running the backend restarted. For 90 seconds, every claim submission returned an error. 23 members tried to submit. 23 members saw a blank screen. Four of them emailed support.
>
> The post-mortem was short: one container, one point of failure, zero redundancy.
>
> The team tried running two containers behind a load balancer. It worked, until a deploy took both containers down simultaneously. They tried staggering restarts manually. It worked, until someone forgot the procedure at 11 PM.
>
> *"We need something that manages containers for us,"* the CTO said. *"Something that knows how to restart them, roll them out safely, and keep a minimum number running at all times."*
>
> The decision: Kubernetes. Run the platform on GKE. Let the orchestrator handle restarts, rollouts, and replicas.

---

## What was built

- Deployed the CoverLine backend and frontend as Kubernetes Deployments with 2 replicas each
- Exposed services via ClusterIP and routed external traffic through an nginx Ingress controller
- Injected environment configuration via a ConfigMap (no hardcoded values in manifests)
- Simulated a failing pod (bad image tag) and practiced debugging + rollback

## Architecture

```
Internet
    └── LoadBalancer (GCP)
            └── nginx Ingress (35.193.169.18)
                    ├── /        → frontend:3000
                    └── /api/*   → backend:5000
```

## How to deploy

```bash
# Apply all manifests
kubectl apply -f phase-2-kubernetes/configmap.yaml
kubectl apply -f phase-2-kubernetes/backend/
kubectl apply -f phase-2-kubernetes/frontend/
kubectl apply -f phase-2-kubernetes/ingress.yaml
```

Install the nginx ingress controller if not present:
```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.10.1/deploy/static/provider/cloud/deploy.yaml
kubectl wait --namespace ingress-nginx --for=condition=ready pod --selector=app.kubernetes.io/component=controller --timeout=90s
```

## Verify

```bash
kubectl get pods
kubectl get ingress coverline-ingress

# Test endpoints
curl http://<INGRESS_IP>/
curl http://<INGRESS_IP>/api/health
curl http://<INGRESS_IP>/api/data
```

## Teardown

```bash
kubectl delete -f phase-2-kubernetes/
```

---

## Troubleshooting

### 1. `ImagePullBackOff` — permission denied

**Cause:** GKE nodes can't pull from Artifact Registry.

**Fix:** Grant the compute service account reader access:
```bash
gcloud projects add-iam-policy-binding <PROJECT_ID> \
  --member="serviceAccount:<PROJECT_NUMBER>-compute@developer.gserviceaccount.com" \
  --role="roles/artifactregistry.reader"
kubectl rollout restart deployment/backend deployment/frontend
```

---

### 2. `no match for platform in manifest`

**Cause:** Image built for `linux/arm64` (Apple Silicon) but GKE nodes run `linux/amd64`.

**Fix:** Rebuild with the correct platform:
```bash
docker build --platform linux/amd64 -t <IMAGE> . && docker push <IMAGE>
```

---

### 3. Pod stuck in `ImagePullBackOff` after IAM fix

**Cause:** Kubernetes backoff timer — pod won't retry immediately.

**Fix:** Force a restart:
```bash
kubectl rollout restart deployment/backend deployment/frontend
```

---

### 4. Rolling back a bad deploy

```bash
# Simulate bad deploy
kubectl set image deployment/backend backend=<IMAGE>:broken

# Debug
kubectl get pods
kubectl describe pod <pod-name>
kubectl logs <pod-name>

# Roll back
kubectl rollout undo deployment/backend
kubectl rollout status deployment/backend
```

---

## Production Considerations

### 1. Add PodDisruptionBudgets (PDB)
In this lab, Kubernetes can remove all pods from a Deployment simultaneously during a node upgrade. In production, a PDB guarantees a minimum number of replicas remain available during maintenance operations, preventing service outages.

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: backend-pdb
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app: coverline-backend
```

### 2. Implement NetworkPolicies
By default, all pods in a Kubernetes cluster can communicate with each other. In production, a compromised pod can reach the database directly. NetworkPolicies restrict traffic flows: only the backend can talk to PostgreSQL, only the frontend can talk to the backend.

```yaml
# Example: only the backend can access PostgreSQL
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: postgresql-access
spec:
  podSelector:
    matchLabels:
      app: postgresql
  ingress:
    - from:
      - podSelector:
          matchLabels:
            app: coverline-backend
```

### 3. Never use the `default` namespace in production
This lab deploys everything into `default`. In production, each service or team should have its own namespace to isolate resources, apply quotas, and limit blast radius during incidents.

### 4. Configure ResourceQuotas per namespace
Without quotas, a single Deployment can consume all cluster memory and evict other services. In production, ResourceQuotas per namespace guarantee fair resource allocation.

```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: coverline-quota
  namespace: coverline
spec:
  hard:
    requests.cpu: "4"
    requests.memory: 4Gi
    limits.cpu: "8"
    limits.memory: 8Gi
```

### 5. Use an Ingress with TLS
This lab exposes services over HTTP. In production, the Ingress must terminate TLS with a valid certificate. cert-manager with Let's Encrypt automates certificate renewal on GKE.

### 6. Set a `revisionHistoryLimit`
By default, Kubernetes keeps 10 versions of each Deployment. In production with frequent deploys, this wastes storage unnecessarily. A value of 3 is generally sufficient to support rollbacks.
