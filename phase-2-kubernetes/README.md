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

---

## Production Considerations

### 1. Ajouter des PodDisruptionBudgets (PDB)
Dans ce lab, Kubernetes peut supprimer tous les pods d'un Deployment en même temps lors d'une mise à jour de node. En production, un PDB garantit qu'un minimum de réplicas reste disponible pendant les opérations de maintenance, évitant les coupures de service.

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

### 2. Mettre en place des NetworkPolicies
Par défaut, tous les pods d'un cluster Kubernetes peuvent communiquer entre eux. En production, un pod compromis peut atteindre directement la base de données. Les NetworkPolicies restreignent les flux : seul le backend peut parler à PostgreSQL, seul le frontend peut parler au backend.

```yaml
# Exemple : seul le backend peut accéder à PostgreSQL
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

### 3. Ne jamais utiliser le namespace `default` en production
Ce lab déploie tout dans `default`. En production, chaque service ou équipe doit avoir son propre namespace pour isoler les ressources, appliquer des quotas, et limiter le blast radius en cas d'incident.

### 4. Configurer des Resource Quotas par namespace
Sans quotas, un seul Deployment peut consommer toute la mémoire du cluster et évincer les autres services. En production, des ResourceQuotas par namespace garantissent une allocation équitable des ressources.

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

### 5. Utiliser un Ingress avec TLS
Ce lab expose le service en HTTP. En production, l'Ingress doit terminer TLS avec un certificat valide. cert-manager avec Let's Encrypt automatise le renouvellement des certificats sur GKE.

### 6. Définir un `revisionHistoryLimit`
Par défaut, Kubernetes conserve 10 versions de chaque Deployment. En production avec des déploiements fréquents, cela consomme de l'espace inutilement. Une valeur de 3 est généralement suffisante pour pouvoir rollback.
