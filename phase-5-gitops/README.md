# Phase 5 — GitOps with ArgoCD

## What was built

- ArgoCD installed on GKE via the official manifests
- Two ArgoCD Applications watching the `main` branch of this repo:
  - `coverline-backend` → `phase-3-helm/charts/backend`
  - `coverline-frontend` → `phase-3-helm/charts/frontend`
- Automated sync with self-heal and prune enabled
- GitOps loop verified: change `values.yaml` → push to main → ArgoCD auto-syncs → cluster updated

## Screenshots

### Applications — Synced & Healthy
![ArgoCD Applications](screenshots/argocd-apps.png)

### Backend — Resource Graph
![ArgoCD Backend Graph](screenshots/argocd-backend-graph.png)

### Sync History
![ArgoCD Sync History](screenshots/argocd-sync-history.png)

---

## GitOps Flow

```
Developer pushes to main
    └── ArgoCD polls repo every 3 minutes
            └── Detects diff between repo and cluster state
                    └── Auto-syncs — applies Helm chart changes
                            └── Cluster matches repo state
```

## Install ArgoCD

```bash
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl get pods -n argocd -w
```

## Access the UI

```bash
# Get admin password
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d && echo

# Port-forward
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

Open `https://localhost:8080` — login: `admin` / password from above.

## Deploy ArgoCD Applications

```bash
kubectl apply -f phase-5-gitops/argocd-app-backend.yaml
kubectl apply -f phase-5-gitops/argocd-app-frontend.yaml
kubectl get applications -n argocd
```

## Verify GitOps loop

```bash
# Change a value in git and push to main
# Example: scale backend to 3 replicas
vim phase-3-helm/charts/backend/values.yaml  # replicaCount: 3
git add . && git commit -m "scale backend to 3" && git push origin main

# Watch ArgoCD sync automatically (within 3 minutes)
kubectl get pods -w
kubectl get applications -n argocd -w
```

## Teardown

```bash
kubectl delete -f phase-5-gitops/
kubectl delete namespace argocd
```

---

## Troubleshooting

### 1. Application stuck in `Progressing`

**Cause:** Backend pods can't start without PostgreSQL and Redis.

**Fix:** Deploy the dependencies first:
```bash
helm install postgresql bitnami/postgresql \
  --set auth.username=coverline \
  --set auth.password=coverline123 \
  --set auth.database=coverline \
  --set primary.persistence.size=1Gi

helm install redis bitnami/redis \
  --set auth.enabled=false \
  --set master.persistence.size=1Gi
```

### 2. ArgoCD not detecting changes

**Cause:** ArgoCD polls every 3 minutes by default.

**Fix:** Force an immediate sync from the UI or CLI:
```bash
kubectl -n argocd exec -it deploy/argocd-server -- argocd app sync coverline-backend
```

---

## Production Considerations

### 1. Adopter le pattern App of Apps
Dans ce lab, chaque application ArgoCD est déclarée dans un fichier YAML séparé appliqué manuellement. En production avec de nombreux services, le pattern "App of Apps" permet à une ArgoCD Application parente de gérer toutes les autres — un seul point d'entrée pour tout le cluster, versionné dans Git.

```yaml
# app-of-apps.yaml — gère toutes les apps depuis un seul endroit
spec:
  source:
    path: apps/          # contient backend.yaml, frontend.yaml, monitoring.yaml...
```

### 2. Configurer les notifications ArgoCD
Ce lab ne notifie personne en cas de sync failure ou de drift. En production, ArgoCD Notifications envoie des alertes vers Slack, PagerDuty ou Teams dès qu'une application est OutOfSync ou Degraded — avant que les utilisateurs ne remarquent le problème.

### 3. Utiliser des webhooks GitHub plutôt que le polling
ArgoCD poll le repo toutes les 3 minutes par défaut. En production, configurer un webhook GitHub qui notifie ArgoCD immédiatement à chaque push réduit le délai de sync de 3 minutes à quelques secondes — critique pour des déploiements fréquents.

### 4. Gérer plusieurs clusters avec ArgoCD
Ce lab utilise ArgoCD pour déployer sur un seul cluster. En production, une instance ArgoCD centralisée (hub-and-spoke) peut gérer des dizaines de clusters (dev, staging, prod, multi-région) depuis un seul point de contrôle avec des politiques RBAC par équipe.

### 5. Séparer le repo applicatif du repo de config
Dans ce lab, le code source et les Helm values sont dans le même repo. En production, les modifications de config (changer une variable d'env, scaler un service) ne devraient pas déclencher un rebuild de l'image. Séparer les deux repos permet de déployer une nouvelle config sans recompiler le code.

### 6. Limiter `selfHeal` en production avec des sync windows
`selfHeal: true` corrige automatiquement tout drift — ce qui est puissant mais peut être dangereux si un opérateur fait un changement d'urgence en production. Les Sync Windows ArgoCD permettent de désactiver l'auto-sync pendant les heures de faible trafic ou les périodes de maintenance.
