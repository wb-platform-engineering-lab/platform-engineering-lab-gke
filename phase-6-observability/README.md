# Phase 6 — Observability Stack

## What was built

- Prometheus + Alertmanager via kube-prometheus-stack
- Grafana with pre-installed Kubernetes dashboards
- Loki for log aggregation
- Promtail as log collector (DaemonSet — one pod per node)
- 3 PrometheusRule alerts for CoverLine (CrashLooping, HighMemory, BackendDown)

## Screenshots

### Grafana — Kubernetes Dashboards
![Grafana Dashboards](screenshots/grafana-dashboards.png)

### Grafana — CoverLine Logs (Loki)
![Grafana Logs](screenshots/grafana-logs.png)

### Prometheus — Alerts
![Prometheus Alerts](screenshots/prometheus-alerts.png)

---

## Prerequisites

Phase 6 requires the CoverLine apps to be running in the cluster.
On a fresh cluster, redeploy ArgoCD and let it sync the apps automatically:

```bash
# Install ArgoCD
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl get pods -n argocd -w

# Deploy CoverLine applications
kubectl apply -f phase-5-gitops/argocd-app-backend.yaml
kubectl apply -f phase-5-gitops/argocd-app-frontend.yaml
kubectl get applications -n argocd
```

Also install PostgreSQL and Redis dependencies if not already present:

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

---

## Install the Observability Stack

```bash
# Add Helm repos
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

# Create namespace
kubectl create namespace monitoring

# Install Prometheus + Grafana + Alertmanager
helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  -f phase-6-observability/kube-prometheus-stack-values.yaml

# Install Loki
helm install loki grafana/loki \
  --namespace monitoring \
  -f phase-6-observability/loki-values.yaml

# Install Promtail
helm install promtail grafana/promtail \
  --namespace monitoring \
  -f phase-6-observability/promtail-values.yaml
```

---

## Access the UIs

### Grafana

```bash
kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80
```

Open `http://localhost:3000` — login: `admin` / `admin123`

### Prometheus

```bash
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090
```

Open `http://localhost:9090`

### ArgoCD

```bash
# Get admin password
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d && echo

# Port-forward
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

Open `https://localhost:8080` — login: `admin` / password from above.

---

## Connect Loki to Grafana

1. Open Grafana → **Connections → Data sources → Add data source**
2. Select **Loki** (Core plugin)
3. URL: `http://loki-gateway.monitoring.svc.cluster.local`
4. Click **Save & test**

---

## Production Diagnostic Queries (LogQL — Loki)

These are the queries you reach for first when something breaks in production.
Run them in **Grafana → Explore → Loki**.

---

### 1. Tous les erreurs d'un namespace — vue d'ensemble immédiate

```logql
{namespace="default"} |= "error" or "ERROR" or "Error"
```

**Quand l'utiliser :** première requête lors d'un incident — tu identifies quel pod génère des erreurs avant d'aller plus loin.

---

### 2. Logs d'un pod spécifique — zoom sur le backend CoverLine

```logql
{namespace="default", app="coverline-backend"} | json
```

**Quand l'utiliser :** le backend répond en erreur, tu veux voir ses logs structurés en JSON pour identifier la cause exacte (connexion DB, timeout Redis, exception Python).

---

### 3. Erreurs HTTP 5xx — incidents API en production

```logql
{namespace="default"} | json | status >= 500
```

**Quand l'utiliser :** le taux d'erreur monte sur ton dashboard — tu veux voir quelles requêtes échouent et avec quel message.

---

### 4. Taux d'erreurs par pod sur les 5 dernières minutes — quel pod est malade ?

```logql
sum by (pod) (
  rate({namespace="default"} |= "error" [5m])
)
```

**Quand l'utiliser :** plusieurs pods tournent, tu veux savoir lequel génère le plus d'erreurs sans lire les logs un par un.

---

### 5. Logs de crash / OOMKill — pod tué par manque de mémoire

```logql
{namespace="default"} |= "OOMKilled" or "out of memory" or "killed"
```

**Quand l'utiliser :** un pod redémarre en boucle, tu veux confirmer que c'est un problème mémoire avant d'ajuster les `limits`.

---

### 6. Logs des dernières 15 minutes avant un incident — timeline d'un post-mortem

```logql
{namespace="default", app="coverline-backend"}
  | json
  | line_format "{{.time}} [{{.level}}] {{.message}}"
```

Avec la plage de temps définie sur l'heure de l'incident dans Grafana.

**Quand l'utiliser :** post-mortem — tu reconstituent la séquence exacte des événements.

---

### 7. Slow queries PostgreSQL — requêtes lentes détectées dans les logs

```logql
{namespace="default", app="postgresql"} |= "duration"
  | regexp `duration: (?P<duration_ms>\d+\.\d+) ms`
  | duration_ms > 500
```

**Quand l'utiliser :** le backend est lent, tu veux savoir si c'est la DB qui ralentit les appels `/claims`.

---

### 8. Erreurs de connexion Redis — cache indisponible

```logql
{namespace="default"} |= "redis" |= "connection refused" or "timeout" or "ECONNREFUSED"
```

**Quand l'utiliser :** le cache Redis est tombé — les requêtes `/claims` frappent directement PostgreSQL et le temps de réponse explose.

---

### 9. Logs Kubernetes system — événements cluster (evictions, scheduling)

```logql
{namespace="kube-system"} |= "Evicted" or "FailedScheduling" or "OOMKilling"
```

**Quand l'utiliser :** des pods disparaissent sans raison apparente — tu veux voir si le scheduler ou le kubelet les a evictés.

---

### 10. Volume de logs par pod — quel service est le plus verbeux ?

```logql
sum by (pod) (
  count_over_time({namespace="default"}[1h])
)
```

**Quand l'utiliser :** les coûts de stockage Loki augmentent — tu identifies quel service log trop et tu ajustes son niveau de log (`INFO` → `WARNING`).

---

## Troubleshooting

### loki-chunks-cache-0 stuck in Pending

**Cause:** Insufficient memory on nodes (e2-standard-2 with 8GB RAM fills up quickly).

**Fix:** Disable caches in `loki-values.yaml` — already configured:
```yaml
chunksCache:
  enabled: false
resultsCache:
  enabled: false
```

### No logs in namespace `default`

**Cause:** CoverLine apps are not deployed on the fresh cluster.

**Fix:** Redeploy via ArgoCD (see Prerequisites above).
