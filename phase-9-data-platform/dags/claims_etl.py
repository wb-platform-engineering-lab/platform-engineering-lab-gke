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

    DBT_DIR = "/opt/airflow/dags/repo/phase-9-data-platform/dbt"

    run_dbt = BashOperator(
        task_id="dbt_run",
        bash_command=(
            f"pip install dbt-bigquery --quiet && "
            f"dbt run --project-dir {DBT_DIR} --profiles-dir {DBT_DIR} --target prod && "
            f"dbt test --project-dir {DBT_DIR} --profiles-dir {DBT_DIR} --target prod"
        ),
    )

    extract >> load_to_bq >> run_dbt
