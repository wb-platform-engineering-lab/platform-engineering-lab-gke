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
