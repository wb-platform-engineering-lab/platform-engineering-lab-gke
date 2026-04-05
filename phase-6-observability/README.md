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

### 1. All errors in a namespace — immediate overview

```logql
{namespace="default"} |= "error" or "ERROR" or "Error"
```

**When to use:** First query during an incident — identify which pod is generating errors before going further.

---

### 2. Logs from a specific pod — zoom in on the CoverLine backend

```logql
{namespace="default", app="coverline-backend"} | json
```

**When to use:** The backend is returning errors — view structured JSON logs to pinpoint the exact cause (DB connection, Redis timeout, Python exception).

---

### 3. HTTP 5xx errors — API incidents in production

```logql
{namespace="default"} | json | status >= 500
```

**When to use:** Error rate is rising on your dashboard — see exactly which requests are failing and with what message.

---

### 4. Error rate per pod over the last 5 minutes — which pod is unhealthy?

```logql
sum by (pod) (
  rate({namespace="default"} |= "error" [5m])
)
```

**When to use:** Multiple pods are running — find out which one is generating the most errors without reading logs one by one.

---

### 5. Crash / OOMKill logs — pod killed due to memory pressure

```logql
{namespace="default"} |= "OOMKilled" or "out of memory" or "killed"
```

**When to use:** A pod is restarting in a loop — confirm it's a memory issue before adjusting resource `limits`.

---

### 6. Logs from the 15 minutes before an incident — post-mortem timeline

```logql
{namespace="default", app="coverline-backend"}
  | json
  | line_format "{{.time}} [{{.level}}] {{.message}}"
```

Set the time range to the incident window in Grafana.

**When to use:** Post-mortem — reconstruct the exact sequence of events leading to the incident.

---

### 7. Slow PostgreSQL queries — slow queries detected in logs

```logql
{namespace="default", app="postgresql"} |= "duration"
  | regexp `duration: (?P<duration_ms>\d+\.\d+) ms`
  | duration_ms > 500
```

**When to use:** The backend is slow — check whether the DB is the bottleneck slowing down `/claims` calls.

---

### 8. Redis connection errors — cache unavailable

```logql
{namespace="default"} |= "redis" |= "connection refused" or "timeout" or "ECONNREFUSED"
```

**When to use:** Redis is down — `/claims` requests are hitting PostgreSQL directly and response times are spiking.

---

### 9. Kubernetes system logs — cluster events (evictions, scheduling failures)

```logql
{namespace="kube-system"} |= "Evicted" or "FailedScheduling" or "OOMKilling"
```

**When to use:** Pods are disappearing without obvious cause — check whether the scheduler or kubelet evicted them.

---

### 10. Log volume per pod — which service is the most verbose?

```logql
sum by (pod) (
  count_over_time({namespace="default"}[1h])
)
```

**When to use:** Loki storage costs are increasing — identify which service is over-logging and tune its log level (`INFO` → `WARNING`).

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

---

## Production Considerations

### 1. Stocker les métriques Prometheus sur le long terme avec Thanos ou GCS
Dans ce lab, Prometheus conserve 7 jours de métriques en mémoire/disque local. En production, les données historiques sont essentielles pour analyser des tendances, faire du capacity planning, et répondre aux audits. Thanos ou Grafana Mimir permettent de stocker des années de métriques sur GCS à faible coût.

### 2. Configurer Alertmanager pour router vers PagerDuty ou Slack
Ce lab crée des règles d'alerte mais Alertmanager n'est pas configuré pour notifier qui que ce soit. En production, les alertes critiques (BackendDown, PodCrashLooping) doivent déclencher une page PagerDuty avec escalade, tandis que les warnings (HighMemoryUsage) peuvent aller dans un channel Slack.

```yaml
# alertmanager config
route:
  receiver: slack-warnings
  routes:
    - match:
        severity: critical
      receiver: pagerduty-oncall
```

### 3. Définir des SLOs et des error budgets
Ce lab mesure des métriques brutes (CPU, mémoire, restarts). En production, l'équipe doit définir des SLOs (ex: 99.9% des requêtes `/claims` répondent en moins de 500ms) et calculer le burn rate de l'error budget. Grafana SLO ou sloth permettent de générer automatiquement les règles PromQL correspondantes.

### 4. Activer la rétention des logs Loki sur GCS
Ce lab utilise le filesystem local pour Loki — les logs disparaissent si le pod redémarre. En production, Loki doit stocker les chunks sur GCS avec une politique de rétention par namespace (ex: 30 jours pour les logs applicatifs, 90 jours pour les logs d'audit de sécurité).

### 5. Isoler le namespace monitoring avec des NetworkPolicies
Dans ce lab, Prometheus peut scraper n'importe quel pod du cluster. En production, les NetworkPolicies doivent restreindre les accès : seul Prometheus peut contacter les endpoints `/metrics` des services, et seul Grafana peut interroger Prometheus. Cela évite qu'un pod compromis exfiltre des métriques sensibles.

### 6. Ne pas exposer Grafana sans authentification forte
Ce lab accède à Grafana via port-forward avec `admin/admin123`. En production, Grafana doit être exposé via un Ingress avec TLS et authentification SSO (Google OAuth, Okta) — jamais avec un mot de passe partagé. Les dashboards contenant des métriques business (taux de sinistres, revenus) sont des données sensibles.
