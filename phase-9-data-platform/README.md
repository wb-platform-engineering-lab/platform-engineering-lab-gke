# Phase 9 — Data Platform (Airflow + dbt + BigQuery)

---

> **CoverLine — 500,000 covered members. Series B.**
>
> Every Monday morning, the same ritual. A developer connected to the production database, ran an export query, and emailed a CSV to the actuarial team. The actuaries opened it in Excel, cleaned duplicate rows by hand, removed irrelevant columns, and fed the result into their risk models. Three people. Four hours. Every week, without fail.
>
> On a Monday in March, the export script had a silent bug. A JOIN condition was wrong. It duplicated 8,000 claims — without raising an error, without any visible sign that anything was wrong. The data team didn't notice. They cleaned the file as usual and trained the fraud detection model on it.
>
> For three weeks, the model flagged legitimate claims as fraudulent. Reimbursements were blocked. Members called support, confused and frustrated. The bug was discovered by chance during an internal audit — not by any automated check, not by any alert.
>
> The post-mortem was short and brutal: *"We have a data workflow. We don't have a data platform. There is no testing, no monitoring, no audit trail. The pipeline lives in one developer's memory and one cron job nobody owns."*
>
> *"If we're making decisions about fraud — decisions that affect members' health coverage — on a CSV cleaned in Excel, we're not a data-driven company. We just think we are."*

---

## What we'll build

| Component | What it does |
|-----------|-------------|
| **Apache Airflow on Kubernetes** | Orchestrates all data pipelines as versioned, monitored DAGs |
| **dbt (data build tool)** | Transforms raw claims data into clean, tested analytical models in BigQuery |
| **BigQuery dataset** | Cloud data warehouse where transformed data is stored and queried |
| **ETL DAG** | Extracts claims from PostgreSQL, loads to BigQuery, triggers dbt transformations |
| **Data quality tests** | dbt schema tests that fail the pipeline before bad data reaches analysts |
| **Airflow alerts** | Prometheus metrics + alert rules that page on-call when a DAG fails |

---

## Architecture

```
PostgreSQL (GKE)
    │
    ▼
Airflow DAG (GKE — KubernetesExecutor)
    ├── Task 1: extract_claims
    │       └── SELECT from PostgreSQL → write Parquet to GCS
    ├── Task 2: load_to_bigquery
    │       └── GCS Parquet → BigQuery raw.claims table
    └── Task 3: dbt_run
            └── dbt models → BigQuery analytics.claims_clean
                           → BigQuery analytics.fraud_signals
                           └── dbt test (schema + data quality)
                                   └── FAIL → DAG fails → alert fires
```

---

## Prerequisites

Cluster running with all previous phases deployed:

```bash
cd phase-1-terraform && terraform apply
gcloud container clusters get-credentials platform-eng-lab-will-gke \
  --region us-central1 --project platform-eng-lab-will
bash bootstrap.sh --phase 9
```

Enable the BigQuery and Cloud Storage APIs:

```bash
gcloud services enable bigquery.googleapis.com storage.googleapis.com \
  --project platform-eng-lab-will
```

Create the GCS staging bucket used by the ETL pipeline:

```bash
gsutil mb -p platform-eng-lab-will -l us-central1 \
  gs://platform-eng-lab-will-data-staging
```

### Troubleshooting: Airflow pods stuck in `Init:CrashLoopBackOff`

**Symptom:** After `bash bootstrap.sh --phase 9`, Helm exits with `context deadline exceeded` and Airflow pods loop on `Init:CrashLoopBackOff`. The init container log shows:

```
TimeoutError: There are still unapplied migrations after 60 seconds.
MigrationHead(s) in DB: set() | Migration Head(s) in Source Code: {'88344c1d9134'}
```

**Cause:** The Helm install timed out before the `run-airflow-migrations` job could complete. The Airflow metadata tables were never created in PostgreSQL, so every pod's `wait-for-airflow-migrations` init container times out waiting for them.

**Fix:** Run the migration manually in a temporary pod, then restart the Airflow deployments:

```bash
FERNET_KEY=$(kubectl get secret -n airflow airflow-fernet-key \
  -o jsonpath='{.data.fernet-key}' | base64 -d)

kubectl run airflow-migrate --rm -i --restart=Never \
  -n airflow \
  --image=apache/airflow:2.8.1 \
  --env="AIRFLOW__DATABASE__SQL_ALCHEMY_CONN=postgresql+psycopg2://coverline:coverline123@postgresql.default.svc.cluster.local:5432/coverline" \
  --env="AIRFLOW__CORE__FERNET_KEY=${FERNET_KEY}" \
  --env="AIRFLOW__CORE__EXECUTOR=KubernetesExecutor" \
  -- airflow db migrate

kubectl rollout restart deployment/airflow-webserver deployment/airflow-scheduler -n airflow
kubectl rollout restart statefulset/airflow-triggerer -n airflow
```

Verify the migrations ran (should return ~43 tables):

```bash
kubectl exec -n default postgresql-0 -- \
  env PGPASSWORD=coverline123 psql -U coverline -d coverline \
  -c "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='public';"
```

Once the count is ≥ 40, the rollout restart will bring all Airflow pods to `Running`.

### Troubleshooting: Fernet key secret exists but is empty

**Symptom:** Migration pod shows `Error: couldn't find key fernet-key in Secret airflow/airflow-fernet-key` and stays in `CreateContainerConfigError`.

**Cause:** The first `bootstrap.sh` run timed out after creating the namespace and the secret object, but before the secret data was written. The secret exists with no data. When you re-run the bootstrap it sees the secret already exists and skips creation — leaving it empty.

**Fix:**

```bash
kubectl delete secret airflow-fernet-key -n airflow
FERNET_KEY=$(python3 -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())")
kubectl create secret generic airflow-fernet-key --namespace airflow --from-literal=fernet-key="$FERNET_KEY"
```

Then re-run the Helm install.

### Troubleshooting: Airflow triggerer stuck in `Pending` — SSD quota exceeded

**Symptom:** `airflow-triggerer-0` stays `Pending`. PVC `logs-airflow-triggerer-0` shows `ProvisioningFailed: QUOTA_EXCEEDED: Quota 'SSD_TOTAL_GB' exceeded`.

**Cause:** The triggerer StatefulSet creates a log PVC on `standard-rwo` (SSD-backed) storage. If the GCP project has hit its SSD disk quota in the region (default 250 GB), the disk cannot be provisioned.

**Fix:** Disable the triggerer's log persistence in `phase-9-data-platform/airflow/values.yaml` (already done in this repo). Then delete the stuck StatefulSet and PVC so Helm can recreate them without a volume claim:

```bash
kubectl delete statefulset airflow-triggerer -n airflow
kubectl delete pvc logs-airflow-triggerer-0 -n airflow
```

Then re-run the Helm upgrade. The triggerer will use an `emptyDir` volume for logs instead of a PVC.

### Troubleshooting: Wrong PostgreSQL password

**Symptom:** Migration job fails with a PostgreSQL authentication error, or the migration pod loops in `CrashLoopBackOff`.

**Cause:** The password hardcoded in `values.yaml` (`coverline123`) does not match the actual password in the `postgresql` secret. This happens when a previous PostgreSQL PVC exists from an earlier install — Bitnami ignores the Helm password value and uses whatever is stored in the PVC.

**Fix:** Read the actual password from the secret and pass it as a Helm override:

```bash
PG_PASS=$(kubectl get secret postgresql -n default -o jsonpath='{.data.password}' | base64 -d)
helm upgrade --install airflow apache-airflow/airflow --namespace airflow \
  -f phase-9-data-platform/airflow/values.yaml \
  --version "1.13.*" \
  --set "data.metadataConnection.pass=${PG_PASS}"
```

---

Local tools — dbt runs in a virtual environment to avoid conflicts with the system Python.

> **Python version note:** dbt requires Python 3.9–3.12. Python 3.13+ is not yet supported due to
> an incompatibility in the `mashumaro` dependency. If your system Python is 3.13+, install 3.12
> first: `brew install python@3.12`

```bash
python3.12 -m venv ~/.venv/dbt   # use python3 if your system Python is 3.9–3.12
source ~/.venv/dbt/bin/activate
uv pip install "dbt-bigquery>=1.8,<2.0"
dbt --version   # should show 1.8.x or later
```

Add the activate line to your shell profile so the venv is active in every new terminal:

```bash
echo 'source ~/.venv/dbt/bin/activate' >> ~/.zshrc
```

---

## Step 1 — Deploy Airflow on Kubernetes

### Why Airflow

Airflow models pipelines as **Directed Acyclic Graphs (DAGs)** — Python files that define tasks and their dependencies. DAGs are versioned in Git. Every run is logged and visible in the Airflow UI. Failures send alerts. Retries are configurable per task. This is the difference between a pipeline and a cron job.

### Why KubernetesExecutor

Airflow supports multiple executors. The `KubernetesExecutor` spins up a fresh Kubernetes pod for each task and destroys it when the task completes. This means:
- No shared worker state between tasks
- Task resource limits are set per-task, not globally
- A failing task cannot affect other running tasks
- The scheduler itself stays lightweight

### Install via Helm

Add the official Airflow Helm chart:

```bash
helm repo add apache-airflow https://airflow.apache.org
helm repo update
```

Create the namespace and a secret for the Fernet key (used to encrypt connection passwords stored in the Airflow DB):

```bash
kubectl create namespace airflow

FERNET_KEY=$(python3 -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())")
kubectl create secret generic airflow-fernet-key \
  --namespace airflow \
  --from-literal=fernet-key="$FERNET_KEY"
```

Save the following to `phase-9-data-platform/airflow/values.yaml`:

```yaml
executor: KubernetesExecutor

webserver:
  defaultUser:
    enabled: true
    role: Admin
    username: admin
    email: admin@coverline.io
    firstName: Admin
    lastName: User
    password: admin  # change in production

scheduler:
  resources:
    requests:
      cpu: 200m
      memory: 512Mi
    limits:
      cpu: 500m
      memory: 1Gi

workers:
  resources:
    requests:
      cpu: 200m
      memory: 256Mi
    limits:
      cpu: 1000m
      memory: 1Gi

dags:
  gitSync:
    enabled: true
    repo: https://github.com/wb-platform-engineering-lab/platform-engineering-lab-gke.git
    branch: main
    subPath: phase-9-data-platform/dags

logs:
  persistence:
    enabled: true
    size: 5Gi

postgresql:
  enabled: true

fernetKeySecretName: airflow-fernet-key

serviceAccount:
  annotations:
    iam.gke.io/workload-identity-pool: "platform-eng-lab-will.svc.id.goog"
    iam.gke.io/workload-identity-provider: "platform-eng-lab-will.svc.id.goog"
```

Install:

```bash
helm upgrade --install airflow apache-airflow/airflow \
  --namespace airflow \
  --values phase-9-data-platform/airflow/values.yaml \
  --version 1.13.*
```

Wait for all pods to become ready:

```bash
kubectl get pods -n airflow -w
```

Expected — all Running:

```
airflow-scheduler-xxx     2/2   Running
airflow-webserver-xxx     1/1   Running
airflow-postgresql-0      1/1   Running
```

### Access the UI

```bash
kubectl port-forward -n airflow svc/airflow-webserver 8080:8080
```

Open `http://localhost:8080` — login with `admin / admin`.

---

## Step 2 — Grant Airflow Access to GCP

Airflow tasks need to write to GCS and BigQuery. Use **Workload Identity** — the same pattern as the backend service — so no credentials are stored in the cluster.

### Create a GCP service account

```bash
gcloud iam service-accounts create airflow-worker \
  --display-name "Airflow DAG worker" \
  --project platform-eng-lab-will

# BigQuery data editor + job user
gcloud projects add-iam-policy-binding platform-eng-lab-will \
  --member "serviceAccount:airflow-worker@platform-eng-lab-will.iam.gserviceaccount.com" \
  --role roles/bigquery.dataEditor

gcloud projects add-iam-policy-binding platform-eng-lab-will \
  --member "serviceAccount:airflow-worker@platform-eng-lab-will.iam.gserviceaccount.com" \
  --role roles/bigquery.jobUser

# GCS read/write on the staging bucket
gsutil iam ch \
  serviceAccount:airflow-worker@platform-eng-lab-will.iam.gserviceaccount.com:objectAdmin \
  gs://platform-eng-lab-will-data-staging
```

### Bind to the Kubernetes service account

```bash
gcloud iam service-accounts add-iam-policy-binding \
  airflow-worker@platform-eng-lab-will.iam.gserviceaccount.com \
  --role roles/iam.workloadIdentityUser \
  --member "serviceAccount:platform-eng-lab-will.svc.id.goog[airflow/airflow-worker]"

kubectl annotate serviceaccount airflow-worker \
  --namespace airflow \
  iam.gke.io/gcp-service-account=airflow-worker@platform-eng-lab-will.iam.gserviceaccount.com
```

### Register the PostgreSQL connection in Airflow

In the Airflow UI → **Admin → Connections → Add**:

| Field | Value |
|---|---|
| Connection ID | `coverline_postgres` |
| Connection Type | `Postgres` |
| Host | `postgresql.coverline.svc.cluster.local` |
| Schema | `coverline` |
| Login | `coverline` |
| Password | *(retrieve from Vault or Kubernetes secret)* |
| Port | `5432` |

Or via CLI:

```bash
kubectl exec -n airflow deploy/airflow-scheduler -- \
  airflow connections add coverline_postgres \
    --conn-type postgres \
    --conn-host postgresql.coverline.svc.cluster.local \
    --conn-schema coverline \
    --conn-login coverline \
    --conn-password "$(kubectl get secret coverline-postgresql \
        -n coverline -o jsonpath='{.data.postgres-password}' | base64 -d)" \
    --conn-port 5432
```

---

## Step 3 — Create the BigQuery Dataset

```bash
bq --project_id platform-eng-lab-will mk \
  --dataset \
  --location US \
  --description "CoverLine raw ingested data" \
  platform-eng-lab-will:raw

bq --project_id platform-eng-lab-will mk \
  --dataset \
  --location US \
  --description "CoverLine analytics models (dbt output)" \
  platform-eng-lab-will:analytics
```

Verify:

```bash
bq ls --project_id platform-eng-lab-will
```

---

## Step 4 — Write the ETL DAG

Save the following to `phase-9-data-platform/dags/claims_etl.py`.

This DAG runs daily at 2 AM, extracts the previous day's claims from PostgreSQL, writes them to GCS as Parquet, loads them into BigQuery, and triggers dbt.

```python
from datetime import datetime, timedelta
from airflow import DAG
from airflow.providers.postgres.hooks.postgres import PostgresHook
from airflow.providers.google.cloud.transfers.gcs_to_bigquery import GCSToBigQueryOperator
from airflow.operators.python import PythonOperator
from airflow.operators.bash import BashOperator
import pandas as pd

GCS_BUCKET = "platform-eng-lab-will-data-staging"
BQ_PROJECT = "platform-eng-lab-will"
BQ_DATASET = "raw"
BQ_TABLE = "claims"

default_args = {
    "owner": "platform-team",
    "retries": 2,
    "retry_delay": timedelta(minutes=5),
    "email_on_failure": True,
    "email": ["platform-team@coverline.io"],
}


def extract_claims(ds, **context):
    """Extract yesterday's claims from PostgreSQL and write to GCS as Parquet."""
    hook = PostgresHook(postgres_conn_id="coverline_postgres")
    df = hook.get_pandas_df(
        sql="""
            SELECT id, member_id, amount, description, status, created_at
            FROM claims
            WHERE created_at::date = %(ds)s
        """,
        parameters={"ds": ds},
    )

    if df.empty:
        print(f"No claims found for {ds} — skipping.")
        return

    local_path = f"/tmp/claims_{ds}.parquet"
    df.to_parquet(local_path, index=False)

    from google.cloud import storage
    client = storage.Client()
    bucket = client.bucket(GCS_BUCKET)
    blob = bucket.blob(f"claims/date={ds}/claims.parquet")
    blob.upload_from_filename(local_path)
    print(f"Uploaded {len(df)} claims to gs://{GCS_BUCKET}/claims/date={ds}/claims.parquet")


with DAG(
    dag_id="claims_etl",
    description="Extract claims from PostgreSQL → GCS → BigQuery → dbt",
    schedule_interval="0 2 * * *",
    start_date=datetime(2026, 1, 1),
    catchup=False,
    default_args=default_args,
    tags=["coverline", "claims", "etl"],
) as dag:

    extract = PythonOperator(
        task_id="extract_claims",
        python_callable=extract_claims,
    )

    load_to_bq = GCSToBigQueryOperator(
        task_id="load_to_bigquery",
        bucket=GCS_BUCKET,
        source_objects=["claims/date={{ ds }}/claims.parquet"],
        source_format="PARQUET",
        destination_project_dataset_table=f"{BQ_PROJECT}.{BQ_DATASET}.{BQ_TABLE}",
        write_disposition="WRITE_APPEND",
        create_disposition="CREATE_IF_NEEDED",
    )

    run_dbt = BashOperator(
        task_id="dbt_run",
        bash_command=(
            "cd /opt/airflow/dags/../dbt && "
            "dbt run --profiles-dir . --target prod && "
            "dbt test --profiles-dir . --target prod"
        ),
    )

    extract >> load_to_bq >> run_dbt
```

After saving the file and pushing to the repo, git-sync picks it up within 60 seconds. Verify the DAG appears in the UI with no import errors:

```bash
kubectl exec -n airflow deploy/airflow-scheduler -- \
  airflow dags list | grep claims_etl
```

> **Watch for import errors.** DAG parsing errors are silent in the terminal but visible in the Airflow UI under **DAGs → Import Errors**. Always check there if a DAG is not showing up.

---

## Step 5 — Set Up dbt

dbt transforms the raw data in BigQuery (`raw.claims`) into clean, tested analytical models (`analytics.claims_clean`, `analytics.fraud_signals`).

### Project structure

```
phase-9-data-platform/dbt/
├── dbt_project.yml
├── profiles.yml
├── models/
│   ├── staging/
│   │   └── stg_claims.sql          # Light clean of raw.claims
│   └── analytics/
│       ├── claims_clean.sql        # De-duplicated, validated claims
│       ├── fraud_signals.sql       # Derived fraud risk features
│       └── schema.yml              # Column-level tests
├── tests/
│   └── assert_no_duplicate_claims.sql
└── seeds/
    └── claim_status_types.csv
```

### `dbt_project.yml`

```yaml
name: coverline
version: "1.0.0"
profile: coverline

model-paths: ["models"]
test-paths: ["tests"]
seed-paths: ["seeds"]

models:
  coverline:
    staging:
      +materialized: view
    analytics:
      +materialized: table
      +dataset: analytics
```

### `profiles.yml`

```yaml
coverline:
  target: prod
  outputs:
    prod:
      type: bigquery
      method: oauth
      project: platform-eng-lab-will
      dataset: analytics
      location: US
      threads: 4
      timeout_seconds: 300
```

### Staging model — `models/staging/stg_claims.sql`

The staging layer applies minimal cleaning: cast types, rename columns, and filter obviously invalid rows.

```sql
with source as (
    select * from {{ source('raw', 'claims') }}
),

cleaned as (
    select
        cast(id as int64)           as claim_id,
        member_id,
        cast(amount as numeric)     as claim_amount,
        lower(trim(description))    as description,
        lower(status)               as status,
        date(created_at)            as claim_date,
        created_at                  as created_at_ts

    from source
    where id is not null
      and amount > 0
)

select * from cleaned
```

### Analytics model — `models/analytics/claims_clean.sql`

The analytics layer de-duplicates and enriches.

```sql
with staged as (
    select * from {{ ref('stg_claims') }}
),

deduplicated as (
    select *,
        row_number() over (
            partition by claim_id
            order by created_at_ts desc
        ) as row_num
    from staged
),

final as (
    select
        claim_id,
        member_id,
        claim_amount,
        description,
        status,
        claim_date,
        created_at_ts,
        case
            when claim_amount > 5000 then 'high'
            when claim_amount > 1000 then 'medium'
            else 'low'
        end as amount_tier

    from deduplicated
    where row_num = 1
)

select * from final
```

### Fraud signals model — `models/analytics/fraud_signals.sql`

```sql
with claims as (
    select * from {{ ref('claims_clean') }}
),

member_stats as (
    select
        member_id,
        count(*)                    as total_claims_30d,
        sum(claim_amount)           as total_amount_30d,
        avg(claim_amount)           as avg_amount_30d,
        countif(status = 'pending') as pending_count

    from claims
    where claim_date >= date_sub(current_date(), interval 30 day)
    group by member_id
),

signals as (
    select
        member_id,
        total_claims_30d,
        total_amount_30d,
        avg_amount_30d,
        pending_count,
        case
            when total_claims_30d > 10 then true
            when total_amount_30d  > 20000 then true
            when pending_count     > 5 then true
            else false
        end as is_flagged

    from member_stats
)

select * from signals
```

### Data quality tests — `models/analytics/schema.yml`

These tests run as part of `dbt test` inside the DAG. A failure here fails the Airflow task and stops the pipeline before bad data reaches analysts.

```yaml
version: 2

models:
  - name: claims_clean
    description: De-duplicated and validated claims
    columns:
      - name: claim_id
        description: Unique claim identifier
        tests:
          - unique
          - not_null
      - name: member_id
        tests:
          - not_null
      - name: claim_amount
        tests:
          - not_null
          - dbt_utils.expression_is_true:
              expression: "claim_amount > 0"
      - name: status
        tests:
          - accepted_values:
              values: ['pending', 'approved', 'rejected', 'under_review']

  - name: fraud_signals
    description: Per-member fraud risk signals (rolling 30-day window)
    columns:
      - name: member_id
        tests:
          - unique
          - not_null
```

### Custom test — `tests/assert_no_duplicate_claims.sql`

This is the test that would have caught the March bug. It fails if any `claim_id` appears more than once in the raw table.

```sql
-- This test fails (returns rows) if duplicates exist in the raw layer.
-- A DAG run that produces duplicates will fail here before touching analytics.
select
    claim_id,
    count(*) as occurrences
from {{ ref('stg_claims') }}
group by claim_id
having count(*) > 1
```

Run dbt locally to verify all models and tests pass:

```bash
cd phase-9-data-platform/dbt
dbt deps
dbt run --target prod
dbt test --target prod
```

Expected output:

```
16:42:01  Running with dbt=1.7.x
16:42:04  Found 3 models, 8 tests, 1 seed
16:42:08  Completed successfully
16:42:08  Done. PASS=8 WARN=0 ERROR=0 SKIP=0 TOTAL=8
```

---

## Step 6 — Trigger the DAG and Verify End-to-End

Seed the PostgreSQL database with test claims data first:

```bash
kubectl exec -n coverline deploy/coverline-backend -- python3 -c "
import psycopg2, random, os
from datetime import date, timedelta

conn = psycopg2.connect(
    host=os.environ['DB_HOST'], dbname=os.environ['DB_NAME'],
    user=os.environ['DB_USER'], password=os.environ['DB_PASSWORD']
)
cur = conn.cursor()
for i in range(100):
    cur.execute(
        \"INSERT INTO claims (member_id, amount, description, status, created_at) \
         VALUES (%s, %s, %s, %s, current_date - interval '1 day')\",
        (f'MBR{random.randint(1000,9999)}',
         round(random.uniform(50, 8000), 2),
         'test claim', 'pending')
    )
conn.commit()
print('100 test claims inserted for yesterday')
"
```

Trigger the DAG manually:

```bash
# Via Airflow CLI
kubectl exec -n airflow deploy/airflow-scheduler -- \
  airflow dags trigger claims_etl --run-id manual-test-$(date +%Y%m%d)

# Or via the Airflow UI: DAGs → claims_etl → ▶ Trigger DAG
```

Watch the task progression in the UI. Each task turns green on success:

```
extract_claims      ✅ success
load_to_bigquery    ✅ success
dbt_run             ✅ success
```

Verify the data landed in BigQuery:

```bash
bq query --project_id platform-eng-lab-will \
  --use_legacy_sql=false \
  'SELECT count(*) as total, sum(claim_amount) as total_amount
   FROM `platform-eng-lab-will.analytics.claims_clean`'
```

Verify the fraud signals table:

```bash
bq query --project_id platform-eng-lab-will \
  --use_legacy_sql=false \
  'SELECT member_id, total_claims_30d, is_flagged
   FROM `platform-eng-lab-will.analytics.fraud_signals`
   WHERE is_flagged = true
   LIMIT 10'
```

---

## Step 7 — Simulate the March Bug and Confirm the Pipeline Catches It

The March incident happened because duplicated data passed through silently. Now reproduce it and confirm the test catches it.

Insert duplicate claims manually:

```bash
kubectl exec -n coverline deploy/coverline-backend -- python3 -c "
import psycopg2, os
conn = psycopg2.connect(
    host=os.environ['DB_HOST'], dbname=os.environ['DB_NAME'],
    user=os.environ['DB_USER'], password=os.environ['DB_PASSWORD']
)
cur = conn.cursor()
# Duplicate the first 50 claims from yesterday
cur.execute(
    \"INSERT INTO claims (member_id, amount, description, status, created_at) \
     SELECT member_id, amount, description, status, created_at \
     FROM claims \
     WHERE created_at::date = current_date - interval '1 day' \
     LIMIT 50\"
)
conn.commit()
print('50 duplicate claims inserted')
"
```

Trigger the DAG again. The `dbt test` step should fail:

```
extract_claims      ✅ success
load_to_bigquery    ✅ success
dbt_run             ❌ failed
```

In the Airflow UI, click the failed task → **Logs**. You should see:

```
Failure in test assert_no_duplicate_claims (tests/assert_no_duplicate_claims.sql)
  Got 50 results, configured to fail if != 0
```

The pipeline stopped. The analytics tables were not updated with corrupted data. An alert fires. The data team investigates before bad data reaches their models.

This is what should have happened in March.

---

## Step 8 — Alert on DAG Failures

The Prometheus metrics endpoint on the Airflow webserver exposes DAG run states. Wire an alert rule to page on-call when any DAG fails.

### ServiceMonitor for Airflow

Save to `phase-9-data-platform/monitoring/airflow-servicemonitor.yaml`:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: airflow
  namespace: monitoring
  labels:
    release: kube-prometheus-stack
spec:
  namespaceSelector:
    matchNames:
      - airflow
  selector:
    matchLabels:
      component: webserver
  endpoints:
    - port: webserver
      path: /metrics
      interval: 30s
```

```bash
kubectl apply -f phase-9-data-platform/monitoring/airflow-servicemonitor.yaml
```

### Alert rule

Save to `phase-9-data-platform/monitoring/airflow-alerts.yaml`:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: airflow-alerts
  namespace: monitoring
  labels:
    release: kube-prometheus-stack
spec:
  groups:
    - name: airflow
      rules:
        - alert: AirflowDAGFailed
          expr: |
            airflow_dag_run_duration_success == 0
            and on(dag_id)
            changes(airflow_dag_run_duration_failed[10m]) > 0
          for: 1m
          labels:
            severity: critical
          annotations:
            summary: "Airflow DAG {{ $labels.dag_id }} failed"
            description: >
              DAG {{ $labels.dag_id }} has a failed run.
              Check the Airflow UI for details.

        - alert: AirflowSchedulerNotRunning
          expr: airflow_scheduler_heartbeat < 1
          for: 5m
          labels:
            severity: critical
          annotations:
            summary: "Airflow scheduler is not running"
            description: >
              No scheduler heartbeat detected for 5 minutes.
              All DAG scheduling has stopped.
```

```bash
kubectl apply -f phase-9-data-platform/monitoring/airflow-alerts.yaml
```

Verify the alert rule is loaded:

```bash
kubectl exec -n monitoring \
  $(kubectl get pods -n monitoring -l app=prometheus -o jsonpath='{.items[0].metadata.name}') \
  -- wget -qO- http://localhost:9090/api/v1/rules | \
  python3 -m json.tool | grep -A2 "AirflowDAGFailed"
```

---

## Step 9 — Verify End-to-End

Run through the full platform verification:

**1. Scheduled run at 2 AM** — confirm the DAG runs automatically (or trigger manually and watch):

```bash
kubectl exec -n airflow deploy/airflow-scheduler -- \
  airflow dags list-runs --dag-id claims_etl --limit 5
```

**2. Data freshness in BigQuery** — confirm yesterday's claims are present:

```bash
bq query --project_id platform-eng-lab-will \
  --use_legacy_sql=false \
  'SELECT claim_date, count(*) as claims
   FROM `platform-eng-lab-will.analytics.claims_clean`
   GROUP BY claim_date
   ORDER BY claim_date DESC
   LIMIT 7'
```

**3. Duplicate protection** — confirm `assert_no_duplicate_claims` test passes on clean data:

```bash
cd phase-9-data-platform/dbt
dbt test --select assert_no_duplicate_claims --target prod
```

**4. Airflow metrics in Grafana** — open the Grafana dashboard and search for `airflow_dag_run`:

```bash
kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80
```

Navigate to **Explore** → Prometheus data source → query `airflow_dag_run_duration_success`.

**5. Alert fires on failure** — re-run the duplicate insert from Step 7, trigger the DAG, confirm the `AirflowDAGFailed` alert appears in Alertmanager:

```bash
kubectl port-forward -n monitoring svc/kube-prometheus-stack-alertmanager 9093:9093
# Open http://localhost:9093 — AirflowDAGFailed should appear within 1 minute
```

---

## Teardown

```bash
helm uninstall airflow -n airflow
kubectl delete namespace airflow

bq rm -r -f platform-eng-lab-will:raw
bq rm -r -f platform-eng-lab-will:analytics

gsutil rm -r gs://platform-eng-lab-will-data-staging
```

Terraform resources (NAT gateway, GKE) — destroy if not continuing to Phase 10:

```bash
cd phase-1-terraform && terraform destroy
```

---

## Architecture Decision Records

- `docs/decisions/adr-016-airflow-over-prefect.md` — Why Apache Airflow over Prefect or Dagster for orchestration
- `docs/decisions/adr-017-dbt-transformations.md` — Why dbt over custom SQL scripts for transformations

---

## What you built

By the end of this phase, CoverLine has:

| Before | After |
|---|---|
| Manual CSV export every Monday | Automated pipeline runs at 2 AM daily |
| No validation — silent corruption passes through | dbt tests fail the pipeline before bad data reaches analysts |
| No alert when the export fails | Prometheus alert pages on-call within 1 minute of a DAG failure |
| Fraud model trained on stale, hand-cleaned data | Fraud signals model built from fresh, tested data in BigQuery |
| One developer owns the export script | Pipeline versioned in Git, visible in Airflow UI, owned by the team |

The actuarial team has clean, tested data every morning. No CSV. No Excel. No developer.

→ **Next: [Phase 10 — Security Hardening](../phase-10-security/README.md)**
