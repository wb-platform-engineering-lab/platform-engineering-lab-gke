# Phase 10e — FinOps & Cost Visibility

> **FinOps concepts introduced:** Kubecost, cost labels, resource rightsizing, GCP Budget Alerts, BigQuery billing export | **Builds on:** Phase 7 observability stack

[📝 Take the quiz](https://wb-platform-engineering-lab.github.io/platform-engineering-lab-gke/phase-10e-finops/quiz.html)

---

## Concepts introduced

| Concept | What it does | Why we need it |
|---|---|---|
| **Kubecost** | Allocates GKE cost per namespace, deployment, and label in real time | GCP billing shows one number for the entire cluster — no breakdown by team, service, or environment |
| **Cost labels** | `team`, `env`, and `product` labels on every workload | Kubecost can only attribute cost to a label that exists — unlabelled pods show as "unallocated" |
| **Resource rightsizing** | Compares requested vs actual resource usage | A pod requesting 500m CPU and using 50m wastes capacity you are billed for whether used or not |
| **GCP Budget Alerts** | Fires an email when project spend crosses a threshold | A runaway batch job or forgotten load balancer can double the bill before month-end |
| **BigQuery billing export** | Exports every GCP charge to BigQuery queryable by label | Month-over-month cost per team and product, answerable by SQL — what CFOs actually want |

---

## The problem

> *CoverLine — 1,000,000 covered members. Series C budget review.*
>
> The CFO sent a single-line question to the VP of Engineering: *"Which team is spending what on GKE?"*
>
> Nobody could answer it. GCP billing showed €18,000/month on the cluster. But the billing line item said only "Kubernetes Engine" — one number, one cluster, zero breakdown. There were no cost labels on workloads. There was no way to attribute a single euro to claims processing, member portal, or the analytics batch jobs.
>
> Three teams were fighting over node capacity. The analytics team's nightly batch job ran at 10 PM and consumed every available CPU on two nodes. The claims service slowed to a crawl during the same window. Nobody connected those two facts until claims latency spiked during what should have been a quiet night.
>
> *"We found out about a 4-hour outage from a customer. We had no metrics, no alerts, and no centralised logs. We were flying blind."*
>
> The decision: Kubecost for real-time cost allocation inside the cluster, GCP Budget Alerts to prevent surprises, and billing export to BigQuery so the CFO can query cost history from a spreadsheet.

---

## Architecture

```
Prometheus (Phase 6)
    │
    └── Kubecost cost-analyzer (kubecost namespace)
            ├── Reads node pricing from GCP Pricing API
            ├── Reads resource usage metrics from Prometheus
            └── Allocates cost: namespace → deployment → pod label
                    │
                    └── Kubecost UI (port-forward :9090)
                            ├── Allocations: namespace / label / deployment view
                            └── Savings: rightsizing recommendations per container

GCP Billing
    │
    ├── Budget Alert
    │       ├── Threshold 1: 80% of monthly budget → email alert
    │       └── Threshold 2: 100% of monthly budget → email alert
    │
    └── BigQuery export
            └── billing_export.gcp_billing_export_v1_*
                    ├── Query: cost by k8s-namespace (last 30 days)
                    └── Query: cost by team label per invoice month
```

---

## Repository structure

```
phase-10e-finops/
└── (no Kubernetes manifests — Kubecost is installed via Helm;
     budget alerts and BigQuery export are configured via gcloud and GCP Console)
```

---

## Prerequisites

Cluster running with observability stack from Phase 6 (Kubecost reuses the existing Prometheus rather than bundling its own):

```bash
bash bootstrap.sh --phase 10
kubectl get pods -n monitoring
```

Expected: `kube-prometheus-stack-prometheus-*` and `kube-prometheus-stack-grafana-*` pods in `Running` state.

Add the Kubecost Helm repository:

```bash
helm repo add kubecost https://kubecost.github.io/cost-analyzer/
helm repo update
```

---

## Architecture Decision Records

- `docs/decisions/adr-040-kubecost-over-opencost.md` — Why Kubecost free tier over OpenCost for a single-cluster lab
- `docs/decisions/adr-041-label-strategy-team-env-product.md` — Why three-label attribution (team / env / product) over namespace-only allocation
- `docs/decisions/adr-042-bigquery-export-for-cfo-reporting.md` — Why BigQuery over scheduled Kubecost CSV exports for trend analysis

---

## Challenge 1 — Install Kubecost

Kubecost runs as a pod inside the cluster. It reads resource usage from Prometheus (already running in Phase 6) and node pricing from the GCP Pricing API to produce allocation reports at the namespace and workload level.

### Step 1: Create the namespace

```bash
kubectl create namespace kubecost
```

### Step 2: Install Kubecost pointing at the existing Prometheus

The key flags disable the bundled Prometheus and direct Kubecost at the `kube-prometheus-stack` instance in the `monitoring` namespace:

```bash
helm install kubecost kubecost/cost-analyzer \
  --version 2.8.5 \
  --namespace kubecost \
  --set global.clusterId="platform-eng-lab-will-dev-gke" \
  --set kubecostToken="" \
  --set prometheus.enabled=false \
  --set prometheus.fqdn="http://kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090" \
  --set grafana.enabled=false \
  --set persistentVolume.enabled=false
```

### Step 3: Verify the pod is running

```bash
kubectl get pods -n kubecost -w
```

Wait until `kubecost-cost-analyzer-*` reaches `Running`. This typically takes 60–90 seconds.

### Step 4: Open the Kubecost UI

```bash
kubectl port-forward -n kubecost svc/kubecost-cost-analyzer 9090:9090
```

Open `http://localhost:9090`. Navigate to **Allocations** in the left sidebar.

> On first load Kubecost requires 5–10 minutes to populate data — it needs at least one Prometheus scrape cycle to read node pricing and resource metrics. If all costs show $0.00, wait and refresh.

---

## Challenge 2 — Apply cost labels to all workloads

Without labels, Kubecost allocates cost by namespace but not by team or product. The three label keys used here are `team`, `env`, and `product` — these map directly to the CFO's reporting requirements.

### Step 1: Patch the backend deployment

```bash
kubectl patch deployment coverline-backend \
  --patch '{"spec":{"template":{"metadata":{"labels":{"team":"claims","env":"production","product":"claims-processing"}}}}}'
```

### Step 2: Patch the frontend deployment

```bash
kubectl patch deployment coverline-frontend \
  --patch '{"spec":{"template":{"metadata":{"labels":{"team":"portal","env":"production","product":"member-portal"}}}}}'
```

### Step 3: Patch PostgreSQL and Redis

```bash
kubectl patch statefulset postgresql \
  --patch '{"spec":{"template":{"metadata":{"labels":{"team":"platform","env":"production","product":"database"}}}}}'

kubectl patch statefulset redis-master \
  --patch '{"spec":{"template":{"metadata":{"labels":{"team":"platform","env":"production","product":"cache"}}}}}'
```

### Step 4: Verify labels are applied

```bash
kubectl get pods --show-labels | grep -E "team=|env=|product="
```

Kubecost picks up new labels on the next allocation refresh cycle (up to 15 minutes).

---

## Challenge 3 — Explore the Kubecost UI

### Step 1: View cost by namespace

```bash
kubectl port-forward -n kubecost svc/kubecost-cost-analyzer 9090:9090
```

1. Open `http://localhost:9090` → **Allocations**
2. Set time range to **Last 7 days**
3. Group by **Namespace** — this gives the highest-level breakdown
4. Note the most expensive namespace (typically `default` where CoverLine workloads run)

### Step 2: Drill into label-based allocation

1. Change **Aggregate by** to **Label** → select `team`
2. The table shows cost broken down by `claims`, `portal`, and `platform`
3. Switch to `product` to see cost by business feature

### Step 3: View cost by deployment

1. Change **Aggregate by** to **Deployment**
2. Sort by **Total cost** (descending)
3. The most expensive deployment is typically `coverline-backend` or `postgresql`

### Step 4: Check the efficiency column

The **Efficiency** column shows CPU and memory efficiency per workload (actual usage / requested). Workloads below 20% efficiency are the highest priority for rightsizing.

| View | What to look for |
|---|---|
| Namespace → default | Total spend on production workloads |
| Label → team | Cost per engineering team |
| Deployment → sorted by cost | Which service costs the most |
| Efficiency column | Under-utilised workloads wasting budget |

---

## Challenge 4 — Identify and right-size over-provisioned workloads

Teams set resource requests generously during development and rarely revisit them. GKE charges for requested capacity whether it is used or not.

### Step 1: Check actual usage

```bash
kubectl top pods --sort-by=cpu
kubectl top pods --sort-by=memory
```

### Step 2: View Kubecost savings recommendations

1. In the Kubecost UI, click **Savings** in the left sidebar
2. Look for the **Right-size containers** section — this compares Prometheus usage data against requests
3. Workloads with efficiency below 20% appear at the top

### Step 3: Apply a rightsizing recommendation

If `kubectl top` shows the backend using 40m CPU against a 500m request, update the Helm values and redeploy:

```bash
helm upgrade coverline phase-4-helm/charts/backend/ \
  --set resources.requests.cpu=100m \
  --set resources.requests.memory=128Mi \
  --set resources.limits.cpu=500m \
  --set resources.limits.memory=256Mi
```

Verify the rollout:

```bash
kubectl rollout status deployment/coverline-backend
kubectl top pods
```

> Rule of thumb: set `requests` at ~1.5× observed p95 usage. Set `limits` at 2–3× requests. This leaves headroom for spikes while keeping the scheduler's placement decisions accurate.

---

## Challenge 5 — GCP Budget Alert and BigQuery export

### Step 1: Create a monthly budget with threshold alerts

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

This creates a €200/month budget with alerts at 80% (€160) and 100% (€200). Alerts go to billing account administrators by default.

### Step 2: Verify the budget was created

```bash
gcloud billing budgets list \
  --billing-account=$(gcloud billing accounts list --format='value(name)' | head -1)
```

### Step 3: Enable BigQuery billing export

BigQuery billing export must be configured through the GCP Console:

1. Open `https://console.cloud.google.com/billing`
2. Select the billing account linked to `platform-eng-lab-will`
3. Navigate to **Billing export → BigQuery export → Edit settings**
4. Project: `platform-eng-lab-will`
5. Dataset name: `billing_export`
6. Enable **Standard usage cost** export
7. Click **Save**

> BigQuery export is not available via `gcloud` CLI for billing accounts. Data begins appearing within 24 hours of enabling export — it does not backfill historical charges.

### Step 4: Query cost by namespace (after 24 hours)

Run this in the BigQuery console (`https://console.cloud.google.com/bigquery`):

```sql
SELECT
  labels.value                              AS namespace,
  SUM(cost)                                 AS total_cost_eur
FROM
  `platform-eng-lab-will.billing_export.gcp_billing_export_v1_*`,
  UNNEST(labels) AS labels
WHERE
  labels.key = 'k8s-namespace'
  AND DATE(_PARTITIONTIME) >= DATE_SUB(CURRENT_DATE(), INTERVAL 30 DAY)
GROUP BY namespace
ORDER BY total_cost_eur DESC;
```

### Step 5: Query cost by team label

```sql
SELECT
  labels.value AS team,
  SUM(cost)    AS total_cost_eur,
  invoice_month
FROM
  `platform-eng-lab-will.billing_export.gcp_billing_export_v1_*`,
  UNNEST(labels) AS labels
WHERE
  labels.key = 'team'
  AND DATE(_PARTITIONTIME) >= DATE_SUB(CURRENT_DATE(), INTERVAL 30 DAY)
GROUP BY team, invoice_month
ORDER BY invoice_month DESC, total_cost_eur DESC;
```

> Custom Kubernetes labels like `team` only appear in the billing export if GKE **resource usage metering** is enabled on the cluster. Without it, the `k8s-namespace` label is present but `team` and `product` labels are not. Enable it in Terraform under `resource_usage_export_config`.

---

## Teardown

```bash
helm uninstall kubecost -n kubecost
kubectl delete namespace kubecost
```

GCP Budget Alerts and BigQuery export are free and do not need to be removed. The labels added to workloads are harmless to leave in place.

---

## Cost breakdown

| Resource | $/day |
|---|---|
| GKE cluster (Phase 1) | ~$0.66 |
| Kubecost pods | included in node cost |
| Budget alerts and BigQuery export | $0 |
| **Phase 10e additional cost** | **$0** |

---

## FinOps concept: showback before chargeback

FinOps moves cloud spending from an uncontrolled operational expense into a managed, attributed cost. There are two stages:

**Showback** — give teams visibility into what they are spending without billing them internally. Publish a weekly cost-by-team report (Kubecost Allocations → export CSV) to each team's Slack channel. This alone changes behaviour: engineers start right-sizing workloads once they can see the cost. It requires no organisational process changes — just labels and a report.

**Chargeback** — attribute and recover costs within the organisation against internal cost centres. This requires accurate label coverage, agreement on allocation rules, and a finance process to act on the numbers. Move to chargeback only after showback has been running long enough that label coverage is consistent and teams trust the numbers.

The BigQuery queries in Challenge 5 are the foundation for both: they answer the CFO's question directly, and they establish the data model for a chargeback system when the organisation is ready for it.

---

## Production considerations

### 1. Consider OpenCost for open-source cost allocation
Kubecost's free tier covers most lab and small-production use cases but limits multi-cluster views, retention, and SAML SSO to paid tiers. OpenCost is the CNCF-sandbox project implementing the same allocation model. It integrates natively with Prometheus and Grafana with no paid tier — the production-grade open-source path for multi-cluster environments.

### 2. Enforce namespace-per-team isolation for accurate allocation
The most reliable unit of cost allocation is the namespace. When multiple teams share a namespace, Kubecost can only allocate to that namespace. In production, give each team its own namespace — this enables accurate Kubecost allocation, ResourceQuota enforcement per team, and NetworkPolicy isolation at no additional cost.

### 3. Apply ResourceQuotas per namespace
Without ResourceQuotas, one team's workload can consume the entire cluster's CPU budget — exactly the batch-job-starving-claims-service problem described above. Once namespaces are isolated per team:

```bash
kubectl apply -f - <<'EOF'
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

### 4. Enable GKE resource usage metering for full label propagation
Enable `resource_usage_export_config` in Terraform so custom Kubernetes labels appear in the BigQuery billing export. Without this, team and product attribution in Step 5 will be empty even when labels are correctly applied to pods.

### 5. Budget alerts are a backstop, not a circuit breaker
GCP billing data is delayed by up to 24 hours. Budget alerts do not stop spend and will not fire on the same day a threshold is crossed. Use Kubecost for real-time anomaly detection — budgets are for end-of-month safety nets.

---

## Outcome

The CFO's question is now answerable. Kubecost shows cost per namespace, team, and product in real time. The rightsizing view surfaces over-provisioned workloads and the savings they represent. A €200/month budget alert fires before the invoice is a surprise. BigQuery holds the full cost history for trend analysis and executive reporting. The analytics batch job that was silently starving the claims service at 10 PM is now visible — by cost, by team, and by the latency it caused.

---

[Back to main README](../README.md) | [Next: Phase 11 — Capstone](../phase-11-capstone/README.md)
