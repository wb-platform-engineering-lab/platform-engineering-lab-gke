# Phase 10e — FinOps & Cost Visibility (Kubecost)

---

> **CoverLine — 1,000,000 covered members. Series C budget review.**
>
> The CFO sent a single-line question to the VP of Engineering: *"Which team is spending what on GKE?"*
>
> Nobody could answer it. GCP billing showed €18,000/month on the cluster. But the billing line item said only "Kubernetes Engine" — one number, one cluster, zero breakdown. There were no cost labels on workloads. There was no way to attribute a single euro to claims processing, member portal, or the analytics batch jobs.
>
> Three teams were fighting over node capacity. The analytics team's nightly batch job ran at 10 PM and consumed every available CPU on two nodes. The claims service slowed to a crawl during the same window. Nobody connected those two facts until claims latency spiked during what should have been a quiet night.
>
> The CFO's ask: a cost report per team, per service, broken down by namespace and deployment — by end of week. The VP of Engineering had no answer. Not yet.
>
> The decision: Kubecost for real-time cost allocation inside the cluster, GCP Budget Alerts to prevent surprises, and billing export to BigQuery so the CFO can query cost history from a spreadsheet.

---

## What we'll build

| Component | What it does |
|---|---|
| **Kubecost** | Cost allocation per namespace, deployment, and label — real-time |
| **Cost labels** | `team`, `env`, and `product` labels on all workloads for attribution |
| **GCP Budget alerts** | Notify at 80% and 100% of the monthly project budget |
| **GCP Billing → BigQuery** | Cluster-level cost export for trend queries and CFO reporting |
| **Resource rightsizing** | Identify over-provisioned workloads wasting budget |

---

## Prerequisites

Cluster running with bootstrap:
```bash
cd phase-1-terraform && terraform apply
gcloud container clusters get-credentials platform-eng-lab-will-gke \
  --region us-central1 --project platform-eng-lab-will
bash bootstrap.sh --phase 10
```

The observability stack (Prometheus + Grafana) must be running — Kubecost uses the existing Prometheus rather than bundling its own. Verify:
```bash
kubectl get pods -n monitoring
```

Expected output: `kube-prometheus-stack-prometheus-*`, `kube-prometheus-stack-grafana-*`, and `kube-prometheus-stack-operator-*` pods all in `Running` state.

---

## Step 1 — Install Kubecost

### Why a separate cost tool?

GCP billing gives you total cluster spend. It does not tell you which namespace, deployment, or team is responsible for any portion of that number. Kubecost runs inside the cluster, reads actual resource usage and node pricing, and produces allocation reports at the namespace and workload level. It reuses the Prometheus already running in the `monitoring` namespace — no second metrics stack required.

### Add the Kubecost Helm repo

```bash
helm repo add kubecost https://kubecost.github.io/cost-analyzer/
helm repo update
```

### Create the namespace

```bash
kubectl create namespace kubecost
```

### Install Kubecost, pointing at the existing Prometheus

The key flags here disable the bundled Prometheus and direct Kubecost at the `kube-prometheus-stack` instance already running in the `monitoring` namespace.

```bash
helm install kubecost kubecost/cost-analyzer \
  --namespace kubecost \
  --set kubecostToken="" \
  --set prometheus.enabled=false \
  --set prometheus.fqdn="http://kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090" \
  --set grafana.enabled=false \
  --set persistentVolume.enabled=true \
  --set persistentVolume.size=10Gi
```

### Verify the pods are running

```bash
kubectl get pods -n kubecost
```

Wait until `kubecost-cost-analyzer-*` is `Running`. This typically takes 60–90 seconds on a fresh install.

### Access the Kubecost UI

```bash
kubectl port-forward -n kubecost svc/kubecost-cost-analyzer 9090:9090
```

Open `http://localhost:9090` in a browser. The Allocations view (left sidebar) is the primary screen for cost breakdown by namespace.

> **Note:** On first load, Kubecost requires 5–10 minutes to populate data. If all costs show as $0.00, wait and refresh. Kubecost needs at least one Prometheus scrape cycle to read node pricing and resource metrics.

---

## Step 2 — Add cost allocation labels to all workloads

### The problem

Without labels, Kubecost can allocate cost by namespace but not by team or product. If the claims service and the member portal share the `default` namespace, their costs are indistinguishable. Labels on every workload are what make the CFO's question answerable.

The three label keys used here are:
- `team` — the engineering team responsible (e.g. `claims`, `portal`, `platform`)
- `env` — the environment (e.g. `production`, `staging`)
- `product` — the business product (e.g. `claims-processing`, `member-portal`)

### Patch the coverline-backend deployment

```bash
kubectl patch deployment coverline-backend \
  --patch '{"spec":{"template":{"metadata":{"labels":{"team":"claims","env":"production","product":"claims-processing"}}}}}'
```

### Patch the coverline-frontend deployment

```bash
kubectl patch deployment coverline-frontend \
  --patch '{"spec":{"template":{"metadata":{"labels":{"team":"portal","env":"production","product":"member-portal"}}}}}'
```

### Patch PostgreSQL (if installed via Bitnami Helm chart)

```bash
kubectl patch statefulset postgresql \
  --patch '{"spec":{"template":{"metadata":{"labels":{"team":"platform","env":"production","product":"database"}}}}}'
```

### Patch Redis (if installed via Bitnami Helm chart)

```bash
kubectl patch statefulset redis-master \
  --patch '{"spec":{"template":{"metadata":{"labels":{"team":"platform","env":"production","product":"cache"}}}}}'
```

### Verify the labels are applied

```bash
kubectl get pods --show-labels
```

Confirm that `team`, `env`, and `product` appear in the labels column for each relevant pod. After labels are applied, Kubecost picks them up on the next allocation refresh cycle (up to 15 minutes).

---

## Step 3 — View cost breakdown in the Kubecost UI

### Port-forward to the Kubecost UI

```bash
kubectl port-forward -n kubecost svc/kubecost-cost-analyzer 9090:9090
```

Open `http://localhost:9090`.

### Navigate to Allocations

1. Click **Allocations** in the left sidebar.
2. Set the time range to **Last 7 days**.
3. Group by **Namespace** first — this gives the highest-level breakdown.
4. Note the most expensive namespace. On this cluster it will typically be `default` where the CoverLine workloads run.

### Drill into label-based allocation

1. Change the **Aggregate by** dropdown to **Label** → select `team`.
2. The table now shows cost broken down by the `team` label values you applied in Step 2: `claims`, `portal`, `platform`.
3. Switch to `product` to see cost by business feature.

### Identify the most expensive deployment

1. Change **Aggregate by** to **Deployment**.
2. Sort by **Total cost** (descending).
3. The most expensive deployment is almost always `coverline-backend` or `postgresql` — the backend holds the most CPU requests and PostgreSQL holds the largest PVC.

### Metrics to note for the CFO report

| View | What to look for |
|---|---|
| Namespace → default | Total spend on production workloads |
| Label → team | Cost per engineering team |
| Deployment → sorted by cost | Which service is most expensive |
| Efficiency column | CPU and memory efficiency per workload (key for rightsizing) |

---

## Step 4 — Identify over-provisioned workloads

### The problem

Teams set resource requests generously during development and never revisit them. A pod requesting 500m CPU that consistently uses 50m is wasting money — GKE charges for requested capacity whether it is used or not. The analytics batch job may have been allocated a full CPU core to run for one hour per day.

### Check actual usage with kubectl top

```bash
kubectl top pods
kubectl top pods --sort-by=cpu
kubectl top pods --sort-by=memory
```

Compare the output against what each pod has requested:

```bash
kubectl get pods -o json | \
  python3 -c "
import json, sys
pods = json.load(sys.stdin)['items']
for pod in pods:
    name = pod['metadata']['name']
    for c in pod['spec']['containers']:
        req = c.get('resources', {}).get('requests', {})
        print(f\"{name} | {c['name']} | cpu_req={req.get('cpu','?')} | mem_req={req.get('memory','?')}\")
"
```

### View Kubecost savings recommendations

1. In the Kubecost UI, click **Savings** in the left sidebar.
2. Kubecost compares actual usage (from Prometheus) against requested resources and surfaces the largest savings opportunities.
3. Look for the **Right-size containers** section — workloads with efficiency below 20% are the highest priority.

### Example: right-sizing the coverline-backend

If `kubectl top` shows the backend using 40m CPU against a 500m request, reduce the request to match actual peak usage with a safe headroom:

```bash
kubectl patch deployment coverline-backend --patch '{
  "spec": {
    "template": {
      "spec": {
        "containers": [{
          "name": "coverline-backend",
          "resources": {
            "requests": {
              "cpu": "100m",
              "memory": "128Mi"
            },
            "limits": {
              "cpu": "500m",
              "memory": "256Mi"
            }
          }
        }]
      }
    }
  }
}'
```

Verify the rollout:
```bash
kubectl rollout status deployment/coverline-backend
kubectl top pods
```

> **Rule of thumb:** Set requests at ~1.5× observed p95 usage. Set limits at 2–3× requests. This leaves headroom for traffic spikes while keeping the scheduler's placement accurate.

---

## Step 5 — GCP Budget Alert

### The problem

The engineering team gets an unexpected bill at the end of the month. GCP continues to provision resources regardless of spend. A runaway batch job, a forgotten load balancer, or a misconfigured autoscaler can double the bill before anyone notices.

Budget alerts fire an email (and optionally a Pub/Sub message) when spend crosses a threshold. They do not stop spend — but they give the team time to act before the invoice arrives.

### Create a budget for the project

```bash
gcloud billing budgets create \
  --billing-account=$(gcloud billing accounts list --format='value(name)' | head -1) \
  --display-name="platform-eng-lab-will monthly budget" \
  --budget-amount=200EUR \
  --threshold-rule=percent=0.8 \
  --threshold-rule=percent=1.0 \
  --filter-projects=projects/platform-eng-lab-will \
  --calendar-period=MONTH
```

This creates a €200/month budget on the `platform-eng-lab-will` project with alerts at 80% (€160) and 100% (€200). Alerts go to the billing account administrators by default.

### Verify the budget was created

```bash
gcloud billing budgets list \
  --billing-account=$(gcloud billing accounts list --format='value(name)' | head -1)
```

> **Note:** Budget alerts are not real-time. GCP updates cost data with up to a 24-hour delay. Do not rely on budget alerts for immediate cost anomaly detection — use Kubecost for that. Budgets are a backstop, not a circuit breaker.

---

## Step 6 — Export GCP Billing to BigQuery

### Why BigQuery?

The Kubecost UI shows current allocation. The CFO wants a trend — month-over-month cost per team, cost per feature, and cost growth rate. BigQuery billing export makes that possible: every GCP resource charge, labelled and queryable by SQL.

### Enable the BigQuery Billing Export

1. Open the GCP Console: `https://console.cloud.google.com/billing`
2. Select the billing account linked to `platform-eng-lab-will`.
3. Navigate to **Billing export** → **BigQuery export** → **Edit settings**.
4. Set the project to `platform-eng-lab-will`.
5. Create a BigQuery dataset named `billing_export` (or use an existing one).
6. Enable **Standard usage cost** export.
7. Click **Save**.

> BigQuery export is not available via `gcloud` CLI for billing accounts — it must be configured through the console. Once enabled, data appears within 24 hours and is updated daily.

### Sample query: cost by GKE namespace (last 30 days)

Run this in the BigQuery console (`https://console.cloud.google.com/bigquery`), replacing `YOUR_BILLING_ACCOUNT_ID` with the numeric portion of your billing account:

```sql
SELECT
  labels.value                              AS namespace,
  SUM(cost)                                 AS total_cost_eur,
  SUM(cost) / COUNT(DISTINCT invoice_month) AS avg_monthly_cost_eur
FROM
  `platform-eng-lab-will.billing_export.gcp_billing_export_v1_*`,
  UNNEST(labels) AS labels
WHERE
  labels.key = 'k8s-namespace'
  AND DATE(_PARTITIONTIME) >= DATE_SUB(CURRENT_DATE(), INTERVAL 30 DAY)
GROUP BY
  namespace
ORDER BY
  total_cost_eur DESC;
```

### Sample query: cost by team label (last 30 days)

```sql
SELECT
  labels.value                 AS team,
  SUM(cost)                    AS total_cost_eur,
  invoice_month
FROM
  `platform-eng-lab-will.billing_export.gcp_billing_export_v1_*`,
  UNNEST(labels) AS labels
WHERE
  labels.key = 'team'
  AND DATE(_PARTITIONTIME) >= DATE_SUB(CURRENT_DATE(), INTERVAL 30 DAY)
GROUP BY
  team, invoice_month
ORDER BY
  invoice_month DESC, total_cost_eur DESC;
```

> **Note:** GKE propagates Kubernetes labels to GCP billing labels automatically only when the cluster has **resource usage metering** enabled. For full label propagation, enable this under GKE cluster settings → **Security** → **Enable Kubernetes resource usage metering**. Without it, the `k8s-namespace` label is present but custom Kubernetes labels like `team` may not appear in the billing export.

---

## Step 7 — Verify & Screenshot

### Summary verification commands

Run the following to confirm all components are in place:

```bash
# Kubecost running
kubectl get pods -n kubecost

# Labels applied to workloads
kubectl get pods --show-labels | grep -E "team=|env=|product="

# Kubecost UI reachable
kubectl port-forward -n kubecost svc/kubecost-cost-analyzer 9090:9090
# Open http://localhost:9090 in browser

# Budget exists
gcloud billing budgets list \
  --billing-account=$(gcloud billing accounts list --format='value(name)' | head -1)

# Prometheus accessible from kubecost namespace (connectivity check)
kubectl run curl-test --image=curlimages/curl --rm -it --restart=Never \
  -n kubecost -- curl -s http://kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090/-/healthy
```

### Screenshots to take

| Screenshot | How to get it |
|---|---|
| Kubecost Allocations — grouped by namespace | Port-forward → Allocations → Group: Namespace |
| Kubecost Allocations — grouped by team label | Port-forward → Allocations → Group: Label → team |
| Kubecost Savings — container rightsizing | Port-forward → Savings → Right-size containers |
| GCP Budget alert — budget created | GCP Console → Billing → Budgets & alerts |
| BigQuery query results — cost by namespace | BigQuery console → run the namespace query above |

---

## Troubleshooting

### Kubecost shows $0.00 for all allocations

**Cause:** Kubecost has not had time to collect a full data window from Prometheus, or the Prometheus URL is incorrect.

**Check the Prometheus connection:**
```bash
kubectl logs -n kubecost deployment/kubecost-cost-analyzer | grep -i "prometheus\|error\|warn"
```

**Verify the URL is reachable from the kubecost namespace:**
```bash
kubectl run curl-test --image=curlimages/curl --rm -it --restart=Never \
  -n kubecost -- curl -s \
  http://kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090/api/v1/query?query=up
```

If the query returns JSON with `"status":"success"`, Prometheus is reachable. If it times out or returns connection refused, the `prometheus.fqdn` value in your Helm install was wrong. Reinstall with the correct URL:
```bash
helm upgrade kubecost kubecost/cost-analyzer \
  --namespace kubecost \
  --set prometheus.enabled=false \
  --set prometheus.fqdn="http://kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090"
```

If Prometheus is reachable but costs are still $0.00, wait 10 minutes — Kubecost needs multiple scrape intervals to build a cost model.

### Labels applied to pods but not visible in Kubecost

**Cause:** Kubecost caches allocation data in 1-hour windows. Labels applied after the last window refresh will not appear immediately.

**Fix:** Wait up to 15 minutes for the next allocation cycle. To confirm labels are present on the pods (not just missing from Kubecost's cache):
```bash
kubectl get pods --show-labels | grep team
```

If the label appears in kubectl output but not in Kubecost, it is a cache delay — wait. If the label does not appear in kubectl output, the patch did not apply correctly. Re-run the `kubectl patch` command from Step 2 and verify:
```bash
kubectl describe pod <pod-name> | grep -A 10 Labels
```

Also confirm the label key is exactly `team` (lowercase, no namespace prefix). Kubecost matches on the raw Kubernetes label key.

### GCP Budget alert not firing

**Cause:** GCP billing data is delayed by up to 24 hours. A budget alert will not fire on the same day the threshold is crossed.

**Additional causes:**
- The billing export is not enabled — budget alerts require billing data to flow, and there is a dependency on the billing account being linked to the project.
- The alert was created on the wrong billing account. Verify with:
  ```bash
  gcloud billing projects describe platform-eng-lab-will
  ```
  The `billingAccountName` in the output must match the account where the budget was created.

- The alert email goes to billing account administrators. If you are not an administrator on the billing account, you will not receive the email. Check IAM roles on the billing account in the GCP Console.

### BigQuery billing export table is empty

**Cause:** Billing export to BigQuery is not real-time. After enabling the export, data begins appearing within 24 hours. The first export covers from the moment export was enabled — historical data before that date is not backfilled.

**Verify the export is enabled:**
1. GCP Console → Billing → Billing export → BigQuery export
2. Status should show a green checkmark and the dataset name.

**Verify the dataset exists:**
```bash
bq ls --project_id=platform-eng-lab-will billing_export
```

If the dataset does not exist, create it and re-enable the export in the console:
```bash
bq --location=US mk --dataset platform-eng-lab-will:billing_export
```

---

## Production Considerations

### 1. Consider OpenCost as the open-source alternative

Kubecost's free tier covers most lab and small-production use cases, but it has feature limits (multi-cluster views, longer retention, and SAML SSO are paid). OpenCost (`https://www.opencost.io`) is the CNCF-sandbox open-source project that implements the same cost allocation model. It integrates with Prometheus and Grafana natively and has no paid tier. For teams running multiple clusters or needing full customisation, OpenCost with a Grafana dashboard is the production-grade open-source path.

### 2. Adopt FinOps Foundation principles: showback before chargeback

Showback means giving teams visibility into what they are spending without billing them internally. Chargeback means actually attributing and recovering costs within the organisation. Start with showback: publish a weekly cost-by-team report (Kubecost → Allocations → export CSV) to each team's Slack channel. This alone changes behaviour — engineers start right-sizing workloads once they can see the cost. Move to chargeback (tagging cloud costs to internal cost centres) only after cost attribution is accurate and labels are consistently applied.

### 3. Enforce namespace-per-team isolation for accurate allocation

The most reliable unit of cost allocation in Kubernetes is the namespace. When multiple teams share a namespace, Kubecost can only allocate to that namespace — not to the individual teams within it. In production, give each team its own namespace: `namespace: claims`, `namespace: portal`, `namespace: analytics`. This enables accurate Kubecost allocation, ResourceQuota enforcement per team, and NetworkPolicy isolation at no additional cost.

### 4. Apply Kubernetes ResourceQuotas per namespace

Without ResourceQuotas, one team's workload can consume the entire cluster's CPU and memory budget — the batch-job-starving-claims-service problem described at the top of this README. Once namespaces are isolated per team, apply quotas:

```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: ResourceQuota
metadata:
  name: claims-team-quota
  namespace: claims
spec:
  hard:
    requests.cpu: "4"
    requests.memory: 8Gi
    limits.cpu: "8"
    limits.memory: 16Gi
    count/pods: "20"
EOF
```

This makes it impossible for the claims team to exceed its allocated cluster share, regardless of what the analytics team is doing at the same time.

### 5. Use GKE resource usage metering for full label propagation to billing

Standard GCP billing export includes the `k8s-namespace` label automatically. Custom Kubernetes labels (`team`, `product`) only appear in the billing export if GKE resource usage metering is enabled at the cluster level. Enable it in Terraform:

```hcl
resource_usage_export_config {
  enable_network_egress_metering       = true
  enable_resource_consumption_metering = true
  bigquery_destination {
    dataset_id = "billing_export"
  }
}
```

Without this, the BigQuery queries in Step 6 will return results for `k8s-namespace` but not for custom labels. Enable this early — it does not backfill historical data.

---

[📝 Take the Phase 10e quiz](https://wb-platform-engineering-lab.github.io/platform-engineering-lab-gke/phase-10e-finops/quiz.html)
