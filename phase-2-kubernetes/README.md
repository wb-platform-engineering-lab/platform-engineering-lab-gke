# Phase 2 — Kubernetes Core

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
