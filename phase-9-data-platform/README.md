# Phase 9 — Data Platform

---

> **CoverLine — 500,000 members. Every Monday morning.**
>
> Three actuarial analysts. A shared Google Sheet. Four hours.
>
> Every Monday at 7 AM, Amara opened her laptop and started the ritual: export claims data from the production PostgreSQL database to CSV, paste it into Excel, clean the duplicates, join it against the members table (also manually exported), calculate the weekly loss ratio, and email the report to Léa by 11 AM.
>
> Three analysts did versions of this, each with slightly different queries. The reports never matched exactly. When someone asked why the loss ratio differed by 0.3% between the CFO deck and the actuary report, it took two weeks to find the cause: a `WHERE` clause someone had added in February and forgotten to document.
>
> *"We're a 500,000-member insurtech,"* Amara said during the post-mortem. *"We should not be running our business on a Monday morning Excel ritual."*
>
> Léa agreed. *"Build me a pipeline that does this automatically, with tests, so we know the numbers are right."*

---

## What we'll build

| Component | What it does |
|-----------|-------------|
| **BigQuery** | Cloud data warehouse — receives all CoverLine data |
| **Airflow** | Orchestrates the pipeline — runs on schedule, retries on failure |
| **DAG: claims_pipeline** | Extracts from PostgreSQL → loads raw data into BigQuery |
| **dbt** | Transforms raw → staging → marts (loss ratio, claims by member) |
| **dbt tests** | Data quality checks — catches the wrong `WHERE` clause automatically |
| **Airflow DAG: dbt_run** | Runs dbt models after each extraction |

**End result:** Every Monday at 06:00 UTC, a pipeline runs automatically. By 07:00, the data is clean, tested, and available. Amara opens Looker Studio instead of Excel.

---

## Architecture

```
PostgreSQL (prod)
      │
      │  Airflow DAG: claims_pipeline (weekly)
      ▼
BigQuery: coverline_raw
  ├── raw_claims
  ├── raw_members
  └── raw_policies
      │
      │  dbt run
      ▼
BigQuery: coverline_staging
  ├── stg_claims
  ├── stg_members
  └── stg_policies
      │
      │  dbt run
      ▼
BigQuery: coverline_marts
  ├── mart_loss_ratio       ← replaces Amara's Excel formula
  ├── mart_claims_by_member
  └── mart_weekly_summary   ← replaces the Monday morning email
```

---

## Prerequisites

Cluster running with Phase 8 bootstrap:
```bash
bash bootstrap.sh --phase 8
```

GCP APIs enabled:
```bash
gcloud services enable bigquery.googleapis.com \
  bigquerydatatransfer.googleapis.com \
  --project=platform-eng-lab-will
```

Add Airflow Helm repo:
```bash
helm repo add apache-airflow https://airflow.apache.org
helm repo update
```

---

## Step 1 — BigQuery Setup

Create the datasets that will hold CoverLine data.

```bash
# Raw layer — landing zone for data from PostgreSQL
bq mk --dataset \
  --location=US \
  --description="CoverLine raw data" \
  platform-eng-lab-will:coverline_raw

# Staging layer — dbt cleans and validates here
bq mk --dataset \
  --location=US \
  --description="CoverLine staging models" \
  platform-eng-lab-will:coverline_staging

# Marts layer — business-ready tables
bq mk --dataset \
  --location=US \
  --description="CoverLine data marts" \
  platform-eng-lab-will:coverline_marts
```

Verify:
```bash
bq ls --project_id=platform-eng-lab-will
```

Expected output:
```
datasetId
-----------------
coverline_marts
coverline_raw
coverline_staging
```

---

## Step 2 — Deploy Airflow on GKE

Airflow runs on your cluster. It needs a GCP service account to write to BigQuery.

### Create service account for Airflow

```bash
# Service account
gcloud iam service-accounts create airflow-worker \
  --display-name="Airflow Worker" \
  --project=platform-eng-lab-will

# Grant BigQuery permissions
gcloud projects add-iam-policy-binding platform-eng-lab-will \
  --member="serviceAccount:airflow-worker@platform-eng-lab-will.iam.gserviceaccount.com" \
  --role="roles/bigquery.dataEditor"

gcloud projects add-iam-policy-binding platform-eng-lab-will \
  --member="serviceAccount:airflow-worker@platform-eng-lab-will.iam.gserviceaccount.com" \
  --role="roles/bigquery.jobUser"

# Key for Airflow
gcloud iam service-accounts keys create airflow-worker-key.json \
  --iam-account=airflow-worker@platform-eng-lab-will.iam.gserviceaccount.com \
  --project=platform-eng-lab-will
```

### Create namespace and GCP secret

```bash
kubectl create namespace airflow

kubectl create secret generic airflow-gcp-credentials \
  --from-file=credentials.json=airflow-worker-key.json \
  --namespace airflow
```

### Deploy Airflow with Helm

```bash
helm upgrade --install airflow apache-airflow/airflow \
  --namespace airflow \
  -f phase-9-data-platform/airflow-values.yaml \
  --wait --timeout 10m
```

Verify all pods are running:
```bash
kubectl get pods -n airflow
```

Expected:
```
NAME                                  READY   STATUS
airflow-scheduler-xxx                 2/2     Running
airflow-webserver-xxx                 1/1     Running
airflow-worker-xxx                    2/2     Running
airflow-postgresql-0                  1/1     Running
```

### Access the Airflow UI

```bash
kubectl port-forward svc/airflow-webserver 8080:8080 -n airflow &
open http://localhost:8080
# username: admin / password: admin
```

---

## Step 3 — Configure Airflow Connections

Airflow needs to know how to connect to PostgreSQL and BigQuery.

### PostgreSQL connection

In the Airflow UI: **Admin → Connections → +**

| Field | Value |
|-------|-------|
| Conn Id | `postgres_coverline` |
| Conn Type | `Postgres` |
| Host | `postgresql.default.svc.cluster.local` |
| Schema | `coverline` |
| Login | `coverline` |
| Password | `coverline123` |
| Port | `5432` |

Or via CLI:
```bash
kubectl exec -n airflow \
  $(kubectl get pod -n airflow -l component=worker -o jsonpath='{.items[0].metadata.name}') \
  -- airflow connections add postgres_coverline \
    --conn-type postgres \
    --conn-host postgresql.default.svc.cluster.local \
    --conn-schema coverline \
    --conn-login coverline \
    --conn-password coverline123 \
    --conn-port 5432
```

### BigQuery connection

| Field | Value |
|-------|-------|
| Conn Id | `bigquery_coverline` |
| Conn Type | `Google BigQuery` |
| Keyfile Path | `/opt/airflow/secrets/credentials.json` |
| Project Id | `platform-eng-lab-will` |

---

## Step 4 — Deploy the Claims Pipeline DAG

The DAG extracts claims and members from PostgreSQL and loads them into BigQuery.

```bash
# Copy DAGs to the Airflow DAGs folder
kubectl cp phase-9-data-platform/dags/ \
  airflow/$(kubectl get pod -n airflow -l component=scheduler -o jsonpath='{.items[0].metadata.name}'):/opt/airflow/dags/ \
  -n airflow
```

In the Airflow UI, you should now see:
- `claims_pipeline` — weekly extraction from PostgreSQL → BigQuery
- `dbt_run` — runs after claims_pipeline completes

### Trigger manually for the first time

```bash
kubectl exec -n airflow \
  $(kubectl get pod -n airflow -l component=scheduler -o jsonpath='{.items[0].metadata.name}') \
  -- airflow dags trigger claims_pipeline
```

Watch it run:
```bash
# In Airflow UI: DAGs → claims_pipeline → Graph View
# Or via CLI:
kubectl exec -n airflow \
  $(kubectl get pod -n airflow -l component=scheduler -o jsonpath='{.items[0].metadata.name}') \
  -- airflow dags state claims_pipeline $(date +%Y-%m-%dT%H:%M:%S)
```

Verify data landed in BigQuery:
```bash
bq query --use_legacy_sql=false \
  'SELECT COUNT(*) as total_claims FROM `platform-eng-lab-will.coverline_raw.raw_claims`'
```

---

## Step 5 — Setup dbt Project

dbt transforms the raw data into clean, tested, business-ready tables.

### Install dbt

```bash
pip install dbt-bigquery
dbt --version
```

### Configure dbt profile

```bash
mkdir -p ~/.dbt
cat > ~/.dbt/profiles.yml << 'EOF'
coverline:
  target: dev
  outputs:
    dev:
      type: bigquery
      method: service-account
      project: platform-eng-lab-will
      dataset: coverline_staging
      keyfile: ./airflow-worker-key.json
      location: US
      threads: 4
EOF
```

### Run dbt

```bash
cd phase-9-data-platform/dbt

# Install dependencies
dbt deps

# Test connection
dbt debug

# Run all models
dbt run

# Run tests (catches the wrong WHERE clause)
dbt test

# Generate and serve docs
dbt docs generate
dbt docs serve --port 8081 &
open http://localhost:8081
```

Expected output after `dbt run`:
```
Running with dbt=1.7.0
Found 6 models, 12 tests

Concurrency: 4 threads

1 of 6 START sql view model coverline_staging.stg_claims .............. [OK]
2 of 6 START sql view model coverline_staging.stg_members ............. [OK]
3 of 6 START sql view model coverline_staging.stg_policies ............ [OK]
4 of 6 START sql table model coverline_marts.mart_loss_ratio .......... [OK]
5 of 6 START sql table model coverline_marts.mart_claims_by_member .... [OK]
6 of 6 START sql table model coverline_marts.mart_weekly_summary ...... [OK]

Finished running 6 models in 0h 0m 23s.
Completed successfully.
```

Expected output after `dbt test`:
```
12 of 12 PASS ...
Completed successfully.
```

---

## Step 6 — Verify the Loss Ratio

This is the number Amara used to calculate by hand every Monday.

```bash
bq query --use_legacy_sql=false '
SELECT
  week_start,
  total_claims_amount,
  total_premiums,
  ROUND(loss_ratio * 100, 2) AS loss_ratio_pct
FROM `platform-eng-lab-will.coverline_marts.mart_loss_ratio`
ORDER BY week_start DESC
LIMIT 4'
```

Expected output:
```
week_start    total_claims_amount  total_premiums  loss_ratio_pct
2024-01-15    142500.00            210000.00       67.86
2024-01-08    138200.00            208500.00       66.28
2024-01-01    151000.00            211000.00       71.56
2023-12-25    129800.00            209000.00       62.11
```

---

## Step 7 — Schedule & Monitor

### Set the weekly schedule

The DAG is already configured to run every Monday at 06:00 UTC. Enable it in the Airflow UI:

```
DAGs → claims_pipeline → toggle ON
```

Or via CLI:
```bash
kubectl exec -n airflow \
  $(kubectl get pod -n airflow -l component=scheduler -o jsonpath='{.items[0].metadata.name}') \
  -- airflow dags unpause claims_pipeline
```

### Monitor with Airflow

```bash
# List recent runs
kubectl exec -n airflow \
  $(kubectl get pod -n airflow -l component=scheduler -o jsonpath='{.items[0].metadata.name}') \
  -- airflow dags list-runs -d claims_pipeline
```

### Add a Prometheus alert for pipeline failures

```bash
kubectl apply -f phase-9-data-platform/airflow-alerts.yaml
```

---

## Step 8 — Verify & Screenshot

```bash
# Final state
bq ls --project_id=platform-eng-lab-will
bq query --use_legacy_sql=false 'SELECT COUNT(*) FROM `platform-eng-lab-will.coverline_marts.mart_weekly_summary`'

# Airflow DAG runs
kubectl exec -n airflow \
  $(kubectl get pod -n airflow -l component=scheduler -o jsonpath='{.items[0].metadata.name}') \
  -- airflow dags list-runs -d claims_pipeline --limit 5
```

Take screenshots for the README:
- `airflow-dag.png` — DAG graph view showing all tasks green
- `bq-tables.png` — BigQuery datasets and tables
- `dbt-docs.png` — dbt docs lineage graph
- `loss-ratio.png` — mart_loss_ratio query result

---

## Troubleshooting

### Airflow webserver not accessible

```bash
kubectl get pods -n airflow
kubectl logs -n airflow -l component=webserver --tail=50
```

### DAG not showing in UI

DAGs are reloaded every 30 seconds. If it doesn't appear:
```bash
kubectl exec -n airflow \
  $(kubectl get pod -n airflow -l component=scheduler -o jsonpath='{.items[0].metadata.name}') \
  -- airflow dags reserialize
```

### BigQuery permission denied

```bash
# Verify service account has the right roles
gcloud projects get-iam-policy platform-eng-lab-will \
  --flatten="bindings[].members" \
  --filter="bindings.members:airflow-worker@platform-eng-lab-will.iam.gserviceaccount.com"
```

### dbt connection error

```bash
dbt debug  # shows exact connection error
# Most common: wrong keyfile path or wrong project ID in profiles.yml
```

### PostgreSQL connection from Airflow

```bash
# Test connectivity from within the cluster
kubectl run psql-test --rm -it --image=postgres:14 --restart=Never -- \
  psql postgresql://coverline:coverline123@postgresql.default.svc.cluster.local:5432/coverline -c "\dt"
```
