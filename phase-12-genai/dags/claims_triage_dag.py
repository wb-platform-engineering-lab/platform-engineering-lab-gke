"""
Phase 12 — Airflow DAG: Claims Triage
Daily at 06:00 UTC. Fetches pending claims via XCom, runs the triage agent.
"""

from __future__ import annotations

from datetime import datetime, timedelta

from airflow import DAG
from airflow.operators.python import PythonOperator

DEFAULT_ARGS = {
    "owner": "platform-engineering",
    "depends_on_past": False,
    "retries": 2,
    "retry_delay": timedelta(minutes=5),
    "email_on_failure": False,
}


def fetch_pending_claims(**context) -> list[int]:
    """Task 1: query PostgreSQL for pending claim IDs and push to XCom."""
    import os
    import psycopg2

    conn = psycopg2.connect(
        host=os.environ.get("DB_HOST", "postgresql.default.svc.cluster.local"),
        dbname=os.environ.get("DB_NAME", "coverline"),
        user=os.environ.get("DB_USER", "coverline"),
        password=os.environ.get("DB_PASSWORD", "coverline"),
    )
    try:
        cur = conn.cursor()
        cur.execute("SELECT claim_id FROM claims WHERE status = 'pending' ORDER BY claim_id")
        claim_ids = [row[0] for row in cur.fetchall()]
    finally:
        conn.close()

    print(f"fetch_pending_claims: found {len(claim_ids)} pending claims")
    # XCom return value is automatically pushed
    return claim_ids


def run_triage(**context) -> None:
    """Task 2: pull claim IDs from XCom and run the triage agent batch."""
    import sys
    import os

    # Make the DAG directory (where this file lives) importable
    dags_dir = os.path.dirname(__file__)
    if dags_dir not in sys.path:
        sys.path.insert(0, dags_dir)

    from claims_triage_agent import run_batch

    ti = context["ti"]
    claim_ids: list[int] = ti.xcom_pull(task_ids="fetch_pending_claims")

    if not claim_ids:
        print("run_triage: no pending claims — nothing to do")
        return

    print(f"run_triage: triaging {len(claim_ids)} claims: {claim_ids}")
    run_batch(claim_ids)


with DAG(
    dag_id="claims_triage",
    default_args=DEFAULT_ARGS,
    description="Daily claims triage using the Anthropic SDK agent",
    schedule_interval="0 6 * * *",
    start_date=datetime(2024, 1, 1),
    catchup=False,
    tags=["phase-12", "genai", "claims"],
) as dag:

    t1 = PythonOperator(
        task_id="fetch_pending_claims",
        python_callable=fetch_pending_claims,
    )

    t2 = PythonOperator(
        task_id="run_triage",
        python_callable=run_triage,
    )

    t1 >> t2
