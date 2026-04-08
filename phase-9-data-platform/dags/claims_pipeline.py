"""
claims_pipeline.py — Weekly CoverLine data pipeline
Extracts claims + members from PostgreSQL and loads into BigQuery.

Schedule: Every Monday at 06:00 UTC
Replaces: Amara's manual Monday morning CSV export (3 analysts, 4 hours/week)
"""

from datetime import datetime, timedelta
from airflow import DAG
from airflow.providers.postgres.hooks.postgres import PostgresHook
from airflow.providers.google.cloud.hooks.bigquery import BigQueryHook
from airflow.operators.python import PythonOperator

# ── Config ──────────────────────────────────────────────────────────────────
PROJECT_ID = "platform-eng-lab-will"
DATASET_RAW = "coverline_raw"
POSTGRES_CONN = "postgres_coverline"

default_args = {
    "owner": "data-platform",
    "depends_on_past": False,
    "retries": 2,
    "retry_delay": timedelta(minutes=5),
    "email_on_failure": True,
    "email": ["data-team@coverline.fr"],
}

# ── Extraction functions ─────────────────────────────────────────────────────

def extract_and_load_claims(**context):
    """Extract claims from PostgreSQL and load into BigQuery raw layer."""
    execution_date = context["execution_date"]
    week_start = execution_date - timedelta(days=execution_date.weekday())

    print(f"Extracting claims for week starting {week_start.date()}")

    # Extract from PostgreSQL
    pg = PostgresHook(postgres_conn_id=POSTGRES_CONN)
    records = pg.get_records("""
        SELECT
            id,
            member_id,
            amount,
            description,
            status,
            created_at,
            updated_at
        FROM claims
        WHERE created_at >= %(week_start)s
          AND created_at < %(week_start)s + INTERVAL '7 days'
        ORDER BY created_at
    """, parameters={"week_start": week_start})

    print(f"Extracted {len(records)} claims records")

    if not records:
        print("No claims for this period — skipping BigQuery load")
        return

    # Load into BigQuery
    bq = BigQueryHook(gcp_conn_id="bigquery_coverline")
    client = bq.get_client()

    rows = [
        {
            "id": r[0],
            "member_id": r[1],
            "amount": float(r[2]) if r[2] else 0.0,
            "description": r[3],
            "status": r[4],
            "created_at": r[5].isoformat() if r[5] else None,
            "updated_at": r[6].isoformat() if r[6] else None,
            "_loaded_at": datetime.utcnow().isoformat(),
            "_week_start": week_start.date().isoformat(),
        }
        for r in records
    ]

    table_id = f"{PROJECT_ID}.{DATASET_RAW}.raw_claims"
    errors = client.insert_rows_json(table_id, rows)

    if errors:
        raise ValueError(f"BigQuery insert errors: {errors}")

    print(f"✓ Loaded {len(rows)} claims into {table_id}")


def extract_and_load_members(**context):
    """Extract members snapshot from PostgreSQL and load into BigQuery."""
    pg = PostgresHook(postgres_conn_id=POSTGRES_CONN)
    records = pg.get_records("""
        SELECT
            id,
            member_id,
            company_id,
            plan_type,
            premium_monthly,
            active,
            enrolled_at
        FROM members
        WHERE active = true
        ORDER BY enrolled_at
    """)

    print(f"Extracted {len(records)} active members")

    if not records:
        print("No members — skipping")
        return

    bq = BigQueryHook(gcp_conn_id="bigquery_coverline")
    client = bq.get_client()

    rows = [
        {
            "id": r[0],
            "member_id": r[1],
            "company_id": r[2],
            "plan_type": r[3],
            "premium_monthly": float(r[4]) if r[4] else 0.0,
            "active": r[5],
            "enrolled_at": r[6].isoformat() if r[6] else None,
            "_loaded_at": datetime.utcnow().isoformat(),
        }
        for r in records
    ]

    table_id = f"{PROJECT_ID}.{DATASET_RAW}.raw_members"
    errors = client.insert_rows_json(table_id, rows)

    if errors:
        raise ValueError(f"BigQuery insert errors: {errors}")

    print(f"✓ Loaded {len(rows)} members into {table_id}")


def run_dbt(**context):
    """Trigger dbt run after raw data is loaded."""
    import subprocess
    result = subprocess.run(
        ["dbt", "run", "--profiles-dir", "/opt/airflow/dbt", "--project-dir", "/opt/airflow/dbt"],
        capture_output=True, text=True
    )
    print(result.stdout)
    if result.returncode != 0:
        print(result.stderr)
        raise RuntimeError("dbt run failed")

    # Run tests
    result = subprocess.run(
        ["dbt", "test", "--profiles-dir", "/opt/airflow/dbt", "--project-dir", "/opt/airflow/dbt"],
        capture_output=True, text=True
    )
    print(result.stdout)
    if result.returncode != 0:
        print(result.stderr)
        raise RuntimeError(f"dbt test failed — data quality issue detected:\n{result.stdout}")

    print("✓ dbt run and tests passed")


# ── DAG definition ───────────────────────────────────────────────────────────

with DAG(
    dag_id="claims_pipeline",
    description="Weekly CoverLine claims → BigQuery pipeline (replaces Monday CSV export)",
    default_args=default_args,
    start_date=datetime(2024, 1, 1),
    schedule_interval="0 6 * * 1",  # Every Monday at 06:00 UTC
    catchup=False,
    tags=["data-platform", "claims", "weekly"],
) as dag:

    extract_claims = PythonOperator(
        task_id="extract_claims",
        python_callable=extract_and_load_claims,
    )

    extract_members = PythonOperator(
        task_id="extract_members",
        python_callable=extract_and_load_members,
    )

    dbt_transform = PythonOperator(
        task_id="dbt_transform",
        python_callable=run_dbt,
    )

    # claims and members extract in parallel, then dbt transforms
    [extract_claims, extract_members] >> dbt_transform
