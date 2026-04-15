# Phase 12 — GenAI & Agentic Platform

---

> **CoverLine — Series D, 3,000,000+ covered members.**
>
> The claims operations team is drowning. With 3 million members, over 8,000 claims are submitted every day. Manual triage — a human reviewer reads the claim, checks the member's policy, cross-references their claim history, and decides whether to approve, flag for review, or reject — takes 48 to 72 hours per claim and costs €4 in reviewer time. At scale, that is €32,000 per day in labour, and the backlog is growing faster than the team can hire.
>
> The medical director's proposal: an AI triage assistant. An agentic system that reads incoming claims, queries the member's policy and history from the database, decides whether to auto-approve, flag for review, or reject, and posts a structured explanation to the case management system. Not a chatbot — a production workflow that runs on a schedule, writes decisions to the database, emits metrics to Prometheus, and can be audited after the fact.
>
> The platform team is tasked with deploying, observing, and governing this system — without touching the ML model itself.
>
> The directive from the CTO: *"I want LLM cost on the same Grafana dashboard as cluster cost. I want to know the p95 response time, the daily token spend, and the decision distribution before I approve this for production. And I want a circuit breaker — if the model starts making unusual decisions at scale, we need to know before the claims team does."*

---

## What we'll build

| Component | What it does |
|-----------|-------------|
| **Claims triage agent** | Python agent using the Anthropic SDK — reads a claim, queries policy and history via tool use, returns a structured `TriageDecision` |
| **Airflow DAG** | Wraps the agent in a scheduled pipeline — runs daily on new claims batches, writes decisions to PostgreSQL |
| **LLM observability** | Prometheus pushgateway metrics for token usage, latency, and cost per claim — Grafana dashboard showing daily spend and decision distribution |
| **Weekly summary agent** | Replaces the manual CSV export from Phase 9 — queries BigQuery for claims trends and posts a structured report to a webhook |
| **On-call assistant** (bonus) | Reads Grafana alert state and Loki logs, posts a root cause hypothesis to a webhook |

---

## Architecture

```
Airflow DAG (daily schedule)
    └── PythonOperator → claims_triage_agent.py
            │
            ├── Tool: query_claim(claim_id)       → PostgreSQL (claims table)
            ├── Tool: get_policy(member_id)        → PostgreSQL (policies table)
            └── Tool: get_claim_history(member_id) → PostgreSQL (claims history)
                    │
                    └── Claude API (claude-sonnet-4-6)
                            │
                            ├── Returns: TriageDecision { decision, confidence, reason }
                            │
                            ├── Write result → PostgreSQL (claims.triage table)
                            └── Emit metrics → Prometheus Pushgateway
                                    └── Grafana dashboard
```

---

## Prerequisites

Phases 1 through 10 must be complete. Phase 12 builds on the PostgreSQL database (Phase 3), the Airflow data platform (Phase 9), and the Prometheus/Grafana observability stack (Phase 6).

Start with a running cluster and the core stack deployed:

```bash
cd phase-1-terraform/envs/dev
terraform init && terraform apply -var-file=dev.tfvars
gcloud container clusters get-credentials platform-eng-lab-will-dev-gke \
  --region us-central1 --project platform-eng-lab-will
cd ../../.. && bash bootstrap.sh --phase 9
```

Verify the required services are running:

```bash
kubectl get pods -n monitoring      # Prometheus + Grafana
kubectl get pods -n airflow         # Airflow scheduler + webserver
kubectl get pods                    # PostgreSQL in default namespace
```

Install the Anthropic SDK locally for testing before deploying to the cluster:

```bash
pip install anthropic psycopg2-binary prometheus-client
```

Set your API key:

```bash
export ANTHROPIC_API_KEY="your-api-key-here"
```

> **Cost note:** Claude API usage during development costs roughly $3/M input tokens and $15/M output tokens (Sonnet pricing). A typical claims triage run (~500 input tokens + ~200 output tokens) costs ~$0.005 per claim. At 8,000 claims/day, that is ~$40/day in production. Testing with a batch of 10–20 seeded claims costs less than $0.10.

---

## Step 1 — Seed the database with test claims

Before building the agent, seed PostgreSQL with realistic test data. The triage agent needs a `claims` table, a `policies` table, and a `claim_history` table to query.

### Connect to PostgreSQL

```bash
kubectl port-forward svc/postgresql 5432:5432 &
```

### Run the seed script

```bash
psql -h localhost -U coverline -d coverline -c "
-- Claims awaiting triage
CREATE TABLE IF NOT EXISTS claims (
    claim_id    SERIAL PRIMARY KEY,
    member_id   INTEGER NOT NULL,
    claim_date  DATE NOT NULL,
    claim_type  VARCHAR(50) NOT NULL,
    amount_eur  NUMERIC(10,2) NOT NULL,
    description TEXT,
    status      VARCHAR(20) DEFAULT 'pending',
    created_at  TIMESTAMP DEFAULT NOW()
);

-- Member policies
CREATE TABLE IF NOT EXISTS policies (
    member_id       INTEGER PRIMARY KEY,
    plan_type       VARCHAR(50) NOT NULL,
    deductible_eur  NUMERIC(10,2) NOT NULL,
    annual_limit_eur NUMERIC(10,2) NOT NULL,
    covered_services TEXT[],
    effective_date  DATE NOT NULL
);

-- Triage decisions written by the agent
CREATE TABLE IF NOT EXISTS claim_triage (
    triage_id   SERIAL PRIMARY KEY,
    claim_id    INTEGER REFERENCES claims(claim_id),
    decision    VARCHAR(20) NOT NULL,  -- approve | review | reject
    confidence  NUMERIC(4,3) NOT NULL, -- 0.000 to 1.000
    reason      TEXT NOT NULL,
    model       VARCHAR(50) NOT NULL,
    input_tokens  INTEGER,
    output_tokens INTEGER,
    latency_ms    INTEGER,
    created_at    TIMESTAMP DEFAULT NOW()
);

-- Seed: policies
INSERT INTO policies VALUES
    (1001, 'standard', 500.00, 10000.00, ARRAY['consultation','specialist','emergency','prescription'], '2024-01-01'),
    (1002, 'premium',  200.00, 25000.00, ARRAY['consultation','specialist','emergency','prescription','dental','physio'], '2024-01-01'),
    (1003, 'basic',   1000.00,  5000.00, ARRAY['consultation','emergency'], '2024-01-01');

-- Seed: claims
INSERT INTO claims (member_id, claim_date, claim_type, amount_eur, description, status) VALUES
    (1001, NOW()::DATE, 'specialist',   450.00, 'Cardiology consultation + ECG', 'pending'),
    (1001, NOW()::DATE, 'prescription', 120.00, 'Monthly diabetes medication', 'pending'),
    (1002, NOW()::DATE, 'dental',       800.00, 'Root canal treatment', 'pending'),
    (1003, NOW()::DATE, 'specialist',   350.00, 'Physiotherapy — 5 sessions', 'pending'),
    (1003, NOW()::DATE, 'prescription',  45.00, 'Antibiotic course', 'pending');
"
```

Verify the tables:

```bash
psql -h localhost -U coverline -d coverline -c "
SELECT c.claim_id, c.member_id, c.claim_type, c.amount_eur, p.plan_type, p.deductible_eur
FROM claims c JOIN policies p ON c.member_id = p.member_id
WHERE c.status = 'pending';
"
```

---

## Step 2 — Build the claims triage agent

### Why the raw Anthropic SDK over LangChain or LlamaIndex?

The Anthropic SDK's tool use feature maps directly to the task: define tools as JSON schemas, call the API, execute the tool functions the model requests, and loop until the model returns a final answer. Adding a framework on top introduces indirection, hidden prompts, and version-lock — none of which help when you need to inspect exactly what the model is doing in a production claims workflow. See `adr-024-agentic-framework.md`.

### Create the agent

Create `phase-12-genai/claims_triage_agent.py`:

```python
import os
import json
import time
import psycopg2
import anthropic
from dataclasses import dataclass
from prometheus_client import CollectorRegistry, Gauge, push_to_gateway

ANTHROPIC_API_KEY = os.environ["ANTHROPIC_API_KEY"]
DB_HOST = os.environ.get("DB_HOST", "localhost")
DB_PORT = int(os.environ.get("DB_PORT", "5432"))
DB_NAME = os.environ.get("DB_NAME", "coverline")
DB_USER = os.environ.get("DB_USER", "coverline")
DB_PASSWORD = os.environ.get("DB_PASSWORD", "coverline")
PUSHGATEWAY_URL = os.environ.get("PUSHGATEWAY_URL", "http://prometheus-pushgateway:9091")


@dataclass
class TriageDecision:
    decision: str       # approve | review | reject
    confidence: float   # 0.0 to 1.0
    reason: str


def get_db_connection():
    return psycopg2.connect(
        host=DB_HOST, port=DB_PORT, dbname=DB_NAME,
        user=DB_USER, password=DB_PASSWORD
    )


# --- Tool implementations ---

def query_claim(claim_id: int) -> dict:
    conn = get_db_connection()
    with conn.cursor() as cur:
        cur.execute(
            "SELECT claim_id, member_id, claim_date, claim_type, amount_eur, description "
            "FROM claims WHERE claim_id = %s",
            (claim_id,)
        )
        row = cur.fetchone()
    conn.close()
    if not row:
        return {"error": f"Claim {claim_id} not found"}
    return {
        "claim_id": row[0], "member_id": row[1], "claim_date": str(row[2]),
        "claim_type": row[3], "amount_eur": float(row[4]), "description": row[5]
    }


def get_policy(member_id: int) -> dict:
    conn = get_db_connection()
    with conn.cursor() as cur:
        cur.execute(
            "SELECT member_id, plan_type, deductible_eur, annual_limit_eur, covered_services "
            "FROM policies WHERE member_id = %s",
            (member_id,)
        )
        row = cur.fetchone()
    conn.close()
    if not row:
        return {"error": f"No policy found for member {member_id}"}
    return {
        "member_id": row[0], "plan_type": row[1], "deductible_eur": float(row[2]),
        "annual_limit_eur": float(row[3]), "covered_services": row[4]
    }


def get_claim_history(member_id: int) -> dict:
    conn = get_db_connection()
    with conn.cursor() as cur:
        cur.execute(
            "SELECT claim_type, amount_eur, claim_date, "
            "COALESCE(ct.decision, 'pending') AS decision "
            "FROM claims c "
            "LEFT JOIN claim_triage ct ON c.claim_id = ct.claim_id "
            "WHERE c.member_id = %s AND c.status != 'pending' "
            "ORDER BY c.claim_date DESC LIMIT 10",
            (member_id,)
        )
        rows = cur.fetchall()
    conn.close()
    return {
        "member_id": member_id,
        "recent_claims": [
            {"claim_type": r[0], "amount_eur": float(r[1]),
             "claim_date": str(r[2]), "decision": r[3]}
            for r in rows
        ]
    }


# --- Tool schema (sent to the model) ---

TOOLS = [
    {
        "name": "query_claim",
        "description": "Retrieve a claim record from the database by claim ID.",
        "input_schema": {
            "type": "object",
            "properties": {
                "claim_id": {"type": "integer", "description": "The claim ID to look up"}
            },
            "required": ["claim_id"]
        }
    },
    {
        "name": "get_policy",
        "description": "Retrieve a member's insurance policy including covered services and limits.",
        "input_schema": {
            "type": "object",
            "properties": {
                "member_id": {"type": "integer", "description": "The member ID to look up"}
            },
            "required": ["member_id"]
        }
    },
    {
        "name": "get_claim_history",
        "description": "Retrieve a member's recent claims history to check for patterns or duplicate claims.",
        "input_schema": {
            "type": "object",
            "properties": {
                "member_id": {"type": "integer", "description": "The member ID to look up"}
            },
            "required": ["member_id"]
        }
    }
]

TOOL_MAP = {
    "query_claim": query_claim,
    "get_policy": get_policy,
    "get_claim_history": get_claim_history,
}

SYSTEM_PROMPT = """You are a claims triage assistant for CoverLine, a digital health insurer.

Your task is to evaluate a health insurance claim and return a triage decision.

Steps:
1. Use query_claim to retrieve the claim details.
2. Use get_policy to check the member's coverage.
3. Use get_claim_history to check for recent similar claims or anomalies.
4. Return a JSON object with exactly these fields:
   {"decision": "approve"|"review"|"reject", "confidence": 0.0-1.0, "reason": "one sentence"}

Decision rules:
- approve: claim type is covered, amount is within policy limits, no duplicate in history
- review: amount is unusually high, claim type is borderline, or history shows anomaly
- reject: claim type is explicitly not covered by the policy

Return ONLY the JSON object as your final response — no surrounding text."""


def triage_claim(claim_id: int) -> tuple[TriageDecision, dict]:
    """Run the triage agent for a single claim. Returns (decision, usage_stats)."""
    client = anthropic.Anthropic(api_key=ANTHROPIC_API_KEY)
    messages = [{"role": "user", "content": f"Triage claim ID {claim_id}."}]

    start = time.time()
    total_input_tokens = 0
    total_output_tokens = 0

    while True:
        response = client.messages.create(
            model="claude-sonnet-4-6",
            max_tokens=1024,
            system=SYSTEM_PROMPT,
            tools=TOOLS,
            messages=messages,
        )

        total_input_tokens += response.usage.input_tokens
        total_output_tokens += response.usage.output_tokens

        if response.stop_reason == "end_turn":
            # Extract the final JSON decision
            text = next(b.text for b in response.content if hasattr(b, "text"))
            data = json.loads(text)
            latency_ms = int((time.time() - start) * 1000)
            decision = TriageDecision(
                decision=data["decision"],
                confidence=float(data["confidence"]),
                reason=data["reason"],
            )
            usage = {
                "input_tokens": total_input_tokens,
                "output_tokens": total_output_tokens,
                "latency_ms": latency_ms,
            }
            return decision, usage

        # Handle tool use
        tool_results = []
        for block in response.content:
            if block.type == "tool_use":
                fn = TOOL_MAP[block.name]
                result = fn(**block.input)
                tool_results.append({
                    "type": "tool_result",
                    "tool_use_id": block.id,
                    "content": json.dumps(result),
                })

        messages.append({"role": "assistant", "content": response.content})
        messages.append({"role": "user", "content": tool_results})


def write_decision(claim_id: int, decision: TriageDecision, usage: dict):
    """Write the triage decision to PostgreSQL."""
    conn = get_db_connection()
    with conn.cursor() as cur:
        cur.execute(
            """INSERT INTO claim_triage
               (claim_id, decision, confidence, reason, model,
                input_tokens, output_tokens, latency_ms)
               VALUES (%s, %s, %s, %s, %s, %s, %s, %s)""",
            (claim_id, decision.decision, decision.confidence, decision.reason,
             "claude-sonnet-4-6",
             usage["input_tokens"], usage["output_tokens"], usage["latency_ms"])
        )
        cur.execute("UPDATE claims SET status = %s WHERE claim_id = %s",
                    (decision.decision, claim_id))
    conn.commit()
    conn.close()


def push_metrics(claim_id: int, decision: TriageDecision, usage: dict):
    """Push per-claim metrics to the Prometheus Pushgateway."""
    registry = CollectorRegistry()

    Gauge("llm_input_tokens_total", "Input tokens used", registry=registry).set(
        usage["input_tokens"])
    Gauge("llm_output_tokens_total", "Output tokens used", registry=registry).set(
        usage["output_tokens"])
    Gauge("llm_latency_ms", "Agent latency in milliseconds", registry=registry).set(
        usage["latency_ms"])
    Gauge("llm_cost_usd", "Estimated cost in USD", registry=registry).set(
        usage["input_tokens"] / 1_000_000 * 3.0 + usage["output_tokens"] / 1_000_000 * 15.0)

    push_to_gateway(
        PUSHGATEWAY_URL,
        job="claims_triage",
        grouping_key={"claim_id": str(claim_id), "decision": decision.decision},
        registry=registry,
    )


def run_batch(claim_ids: list[int]):
    """Triage a batch of claims."""
    for claim_id in claim_ids:
        print(f"Triaging claim {claim_id}...")
        try:
            decision, usage = triage_claim(claim_id)
            write_decision(claim_id, decision, usage)
            push_metrics(claim_id, decision, usage)
            print(f"  → {decision.decision} (confidence={decision.confidence:.2f}) "
                  f"| {usage['input_tokens']}+{usage['output_tokens']} tokens "
                  f"| {usage['latency_ms']}ms")
        except Exception as e:
            print(f"  ✗ Failed: {e}")


if __name__ == "__main__":
    # Get all pending claim IDs and triage them
    conn = get_db_connection()
    with conn.cursor() as cur:
        cur.execute("SELECT claim_id FROM claims WHERE status = 'pending'")
        pending = [row[0] for row in cur.fetchall()]
    conn.close()

    print(f"Found {len(pending)} pending claims.")
    run_batch(pending)
```

### Test locally

With port-forward to PostgreSQL still running:

```bash
python phase-12-genai/claims_triage_agent.py
```

Expected output:

```
Found 5 pending claims.
Triaging claim 1...
  → approve (confidence=0.92) | 487+156 tokens | 2341ms
Triaging claim 2...
  → approve (confidence=0.88) | 512+143 tokens | 1987ms
Triaging claim 3...
  → approve (confidence=0.85) | 521+168 tokens | 2105ms
Triaging claim 4...
  → review (confidence=0.71) | 498+201 tokens | 2489ms
Triaging claim 5...
  → approve (confidence=0.94) | 463+138 tokens | 1876ms
```

Verify decisions were written:

```bash
psql -h localhost -U coverline -d coverline -c "
SELECT c.claim_id, c.claim_type, c.amount_eur, ct.decision, ct.confidence, ct.reason
FROM claims c JOIN claim_triage ct ON c.claim_id = ct.claim_id
ORDER BY ct.created_at DESC;
"
```

---

## Step 3 — Install the Prometheus Pushgateway

The triage agent runs as a batch job (not a long-running process), so it cannot expose a `/metrics` endpoint. The Pushgateway receives metrics pushed by short-lived jobs and holds them for Prometheus to scrape.

### Install via Helm

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

helm install prometheus-pushgateway prometheus-community/prometheus-pushgateway \
  --namespace monitoring \
  --set serviceMonitor.enabled=true \
  --set serviceMonitor.additionalLabels.release=kube-prometheus-stack
```

Verify the Pushgateway is running:

```bash
kubectl get pods -n monitoring | grep pushgateway
```

Verify Prometheus can scrape it (check the Targets page):

```bash
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090
```

Open `http://localhost:9090/targets` and confirm `pushgateway` appears as a target with state `UP`.

---

## Step 4 — Wrap the agent in an Airflow DAG

Create `phase-12-genai/dags/claims_triage_dag.py`:

```python
from datetime import datetime, timedelta
import psycopg2
from airflow import DAG
from airflow.operators.python import PythonOperator

default_args = {
    "owner": "platform",
    "retries": 1,
    "retry_delay": timedelta(minutes=5),
}

with DAG(
    dag_id="claims_triage",
    description="Daily AI triage of pending insurance claims",
    schedule_interval="0 6 * * *",   # 06:00 UTC every day
    start_date=datetime(2024, 1, 1),
    catchup=False,
    default_args=default_args,
    tags=["genai", "claims"],
) as dag:

    def fetch_pending_claims(**context):
        import os
        conn = psycopg2.connect(
            host=os.environ["DB_HOST"],
            dbname=os.environ["DB_NAME"],
            user=os.environ["DB_USER"],
            password=os.environ["DB_PASSWORD"],
        )
        with conn.cursor() as cur:
            cur.execute("SELECT claim_id FROM claims WHERE status = 'pending'")
            pending = [row[0] for row in cur.fetchall()]
        conn.close()
        context["ti"].xcom_push(key="pending_claim_ids", value=pending)
        print(f"Found {len(pending)} pending claims.")

    def run_triage(**context):
        import sys
        sys.path.insert(0, "/opt/airflow/dags")
        from claims_triage_agent import run_batch
        claim_ids = context["ti"].xcom_pull(key="pending_claim_ids", task_ids="fetch_pending_claims")
        if not claim_ids:
            print("No pending claims — skipping.")
            return
        run_batch(claim_ids)

    fetch = PythonOperator(
        task_id="fetch_pending_claims",
        python_callable=fetch_pending_claims,
    )

    triage = PythonOperator(
        task_id="run_triage",
        python_callable=run_triage,
    )

    fetch >> triage
```

### Deploy the DAG to Airflow

Copy the agent and DAG into the Airflow DAGs ConfigMap (or the mounted DAGs PVC, depending on your Airflow install from Phase 9):

```bash
kubectl cp phase-12-genai/claims_triage_agent.py \
  airflow/$(kubectl get pod -n airflow -l component=scheduler -o name | head -1 | cut -d/ -f2):/opt/airflow/dags/claims_triage_agent.py

kubectl cp phase-12-genai/dags/claims_triage_dag.py \
  airflow/$(kubectl get pod -n airflow -l component=scheduler -o name | head -1 | cut -d/ -f2):/opt/airflow/dags/claims_triage_dag.py
```

### Set the API key as an Airflow Secret

```bash
kubectl create secret generic anthropic-api-key \
  --from-literal=ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" \
  --namespace airflow
```

Reference the secret in the Airflow Helm values (`--set env[0].name=ANTHROPIC_API_KEY --set env[0].valueFrom.secretKeyRef.name=anthropic-api-key --set env[0].valueFrom.secretKeyRef.key=ANTHROPIC_API_KEY`), then upgrade:

```bash
helm upgrade airflow apache-airflow/airflow \
  --namespace airflow \
  --reuse-values \
  --set "env[0].name=ANTHROPIC_API_KEY" \
  --set "env[0].valueFrom.secretKeyRef.name=anthropic-api-key" \
  --set "env[0].valueFrom.secretKeyRef.key=ANTHROPIC_API_KEY"
```

### Trigger the DAG manually to test

```bash
kubectl port-forward -n airflow svc/airflow-webserver 8080:8080 &
```

Open `http://localhost:8080`, navigate to **DAGs → claims_triage**, and click **Trigger DAG**. Watch the task logs — they contain per-claim output including token counts and decisions.

---

## Step 5 — Build the LLM observability dashboard

The claims triage agent pushes four metrics per run to the Pushgateway:

| Metric | Type | Description |
|--------|------|-------------|
| `llm_input_tokens_total` | Gauge | Input tokens consumed by the model |
| `llm_output_tokens_total` | Gauge | Output tokens generated by the model |
| `llm_latency_ms` | Gauge | End-to-end agent latency in milliseconds |
| `llm_cost_usd` | Gauge | Estimated cost at Sonnet pricing ($3/$15 per 1M tokens) |

### Create the Grafana dashboard

Import this dashboard JSON into Grafana (Dashboards → Import → Paste JSON):

```json
{
  "title": "CoverLine — LLM Claims Triage",
  "uid": "llm-claims-triage",
  "panels": [
    {
      "title": "Daily cost (USD)",
      "type": "stat",
      "targets": [{ "expr": "sum(llm_cost_usd)" }],
      "fieldConfig": { "defaults": { "unit": "currencyUSD" } }
    },
    {
      "title": "Tokens per claim (p95)",
      "type": "stat",
      "targets": [{ "expr": "histogram_quantile(0.95, sum(rate(llm_input_tokens_total[1d])) by (le))" }]
    },
    {
      "title": "Agent latency p95 (ms)",
      "type": "stat",
      "targets": [{ "expr": "histogram_quantile(0.95, sum(rate(llm_latency_ms[1h])) by (le))" }]
    },
    {
      "title": "Triage decision distribution",
      "type": "piechart",
      "targets": [{ "expr": "count by (decision) (llm_cost_usd)" }]
    },
    {
      "title": "Cost over time",
      "type": "timeseries",
      "targets": [{ "expr": "sum(llm_cost_usd) by (decision)" }]
    }
  ]
}
```

Access Grafana:

```bash
kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80
```

Open `http://localhost:3000` (default credentials: `admin` / check your Helm values for `adminPassword`).

After triggering a few triage runs, the dashboard should show a non-zero daily cost, a decision distribution pie chart, and a latency stat.

---

## Step 6 — Weekly summary agent

The weekly summary agent replaces the manual CSV export described in Phase 9. It queries BigQuery for weekly claims trends and posts a structured report to a webhook.

Create `phase-12-genai/weekly_summary_agent.py`:

```python
import os
import json
import anthropic
from google.cloud import bigquery

ANTHROPIC_API_KEY = os.environ["ANTHROPIC_API_KEY"]
WEBHOOK_URL = os.environ.get("SUMMARY_WEBHOOK_URL", "")
BQ_PROJECT = os.environ.get("BQ_PROJECT", "platform-eng-lab-will")
BQ_DATASET = os.environ.get("BQ_DATASET", "coverline")

client = anthropic.Anthropic(api_key=ANTHROPIC_API_KEY)
bq_client = bigquery.Client(project=BQ_PROJECT)

TOOLS = [
    {
        "name": "query_claims_summary",
        "description": "Query BigQuery for weekly claims summary statistics.",
        "input_schema": {
            "type": "object",
            "properties": {
                "weeks_back": {
                    "type": "integer",
                    "description": "Number of weeks to look back (default 1)"
                }
            },
            "required": []
        }
    }
]


def query_claims_summary(weeks_back: int = 1) -> dict:
    query = f"""
    SELECT
        claim_type,
        COUNT(*) AS total_claims,
        ROUND(SUM(amount_eur), 2) AS total_amount_eur,
        ROUND(AVG(amount_eur), 2) AS avg_amount_eur,
        COUNTIF(ct.decision = 'approve') AS approved,
        COUNTIF(ct.decision = 'review') AS flagged_for_review,
        COUNTIF(ct.decision = 'reject') AS rejected
    FROM `{BQ_PROJECT}.{BQ_DATASET}.claims` c
    LEFT JOIN `{BQ_PROJECT}.{BQ_DATASET}.claim_triage` ct ON c.claim_id = ct.claim_id
    WHERE c.claim_date >= DATE_SUB(CURRENT_DATE(), INTERVAL {weeks_back * 7} DAY)
    GROUP BY claim_type
    ORDER BY total_claims DESC
    """
    rows = list(bq_client.query(query).result())
    return {"summary": [dict(row) for row in rows], "period_weeks": weeks_back}


def run_summary_agent() -> str:
    messages = [{"role": "user", "content":
        "Generate a weekly claims summary report. Query the last week of data. "
        "Write it as a concise executive summary suitable for posting to Slack."}]

    while True:
        response = client.messages.create(
            model="claude-sonnet-4-6",
            max_tokens=1024,
            tools=TOOLS,
            messages=messages,
        )

        if response.stop_reason == "end_turn":
            return next(b.text for b in response.content if hasattr(b, "text"))

        tool_results = []
        for block in response.content:
            if block.type == "tool_use":
                if block.name == "query_claims_summary":
                    result = query_claims_summary(**block.input)
                    tool_results.append({
                        "type": "tool_result",
                        "tool_use_id": block.id,
                        "content": json.dumps(result),
                    })

        messages.append({"role": "assistant", "content": response.content})
        messages.append({"role": "user", "content": tool_results})


if __name__ == "__main__":
    import urllib.request
    summary = run_summary_agent()
    print(summary)

    if WEBHOOK_URL:
        payload = json.dumps({"text": summary}).encode()
        req = urllib.request.Request(
            WEBHOOK_URL, data=payload,
            headers={"Content-Type": "application/json"}
        )
        urllib.request.urlopen(req)
        print("Posted to webhook.")
```

Wrap this in an Airflow DAG with a weekly schedule (`0 8 * * 1` — Monday 08:00 UTC).

---

## Step 7 — On-call assistant (bonus)

The on-call assistant is an agent that fires when a Grafana alert triggers. It reads the alert state, queries recent logs from Loki for the affected service, and posts a structured root cause hypothesis to a webhook — before the on-call engineer has finished reading the PagerDuty notification.

### How it fits into the existing stack

```
Grafana alert fires
    └── Webhook contact point → on_call_assistant.py
            ├── Tool: get_alert_details(alert_name)  → Grafana Alerting API
            ├── Tool: query_loki(service, duration)  → Loki HTTP API
            └── Tool: query_prometheus(promql)       → Prometheus HTTP API
                    │
                    └── Claude API (claude-sonnet-4-6)
                            │
                            └── Posts hypothesis → webhook (Slack / incident channel)
```

### Create the agent

Create `phase-12-genai/on_call_assistant.py`:

```python
import os
import json
import time
import urllib.request
import urllib.parse
from http.server import HTTPServer, BaseHTTPRequestHandler
import anthropic

ANTHROPIC_API_KEY = os.environ["ANTHROPIC_API_KEY"]
GRAFANA_URL = os.environ.get("GRAFANA_URL", "http://kube-prometheus-stack-grafana.monitoring.svc.cluster.local")
GRAFANA_TOKEN = os.environ.get("GRAFANA_TOKEN", "")
LOKI_URL = os.environ.get("LOKI_URL", "http://loki.monitoring.svc.cluster.local:3100")
PROMETHEUS_URL = os.environ.get("PROMETHEUS_URL", "http://kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090")
WEBHOOK_URL = os.environ.get("ONCALL_WEBHOOK_URL", "")

client = anthropic.Anthropic(api_key=ANTHROPIC_API_KEY)

TOOLS = [
    {
        "name": "get_alert_details",
        "description": (
            "Retrieve the current state of a Grafana alert rule — its labels, "
            "annotations, current value, and how long it has been firing."
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "alert_name": {
                    "type": "string",
                    "description": "The name of the Grafana alert rule"
                }
            },
            "required": ["alert_name"]
        }
    },
    {
        "name": "query_loki",
        "description": (
            "Query Loki for recent log lines from a specific service. "
            "Returns up to 50 log lines from the last N minutes."
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "service": {
                    "type": "string",
                    "description": "The Kubernetes app label to filter logs by (e.g. coverline-backend)"
                },
                "duration_minutes": {
                    "type": "integer",
                    "description": "How many minutes back to query (default 15)"
                }
            },
            "required": ["service"]
        }
    },
    {
        "name": "query_prometheus",
        "description": "Run a PromQL instant query and return the current value.",
        "input_schema": {
            "type": "object",
            "properties": {
                "promql": {
                    "type": "string",
                    "description": "The PromQL expression to evaluate"
                }
            },
            "required": ["promql"]
        }
    }
]


def _http_get(url: str, headers: dict = None) -> dict:
    req = urllib.request.Request(url, headers=headers or {})
    with urllib.request.urlopen(req, timeout=10) as resp:
        return json.loads(resp.read())


def get_alert_details(alert_name: str) -> dict:
    headers = {"Authorization": f"Bearer {GRAFANA_TOKEN}"} if GRAFANA_TOKEN else {}
    try:
        data = _http_get(f"{GRAFANA_URL}/api/alertmanager/grafana/api/v2/alerts", headers)
        matching = [a for a in data if a.get("labels", {}).get("alertname") == alert_name]
        if not matching:
            return {"error": f"No active alert named '{alert_name}'"}
        alert = matching[0]
        return {
            "alert_name": alert_name,
            "status": alert.get("status", {}).get("state", "unknown"),
            "labels": alert.get("labels", {}),
            "annotations": alert.get("annotations", {}),
            "starts_at": alert.get("startsAt", ""),
        }
    except Exception as e:
        return {"error": str(e)}


def query_loki(service: str, duration_minutes: int = 15) -> dict:
    query = f'{{app="{service}"}}'
    end = int(time.time() * 1e9)
    start = int((time.time() - duration_minutes * 60) * 1e9)
    params = urllib.parse.urlencode({
        "query": query, "start": start, "end": end, "limit": 50, "direction": "backward"
    })
    try:
        data = _http_get(f"{LOKI_URL}/loki/api/v1/query_range?{params}")
        lines = []
        for stream in data.get("data", {}).get("result", []):
            for ts, line in stream.get("values", []):
                lines.append(line)
        return {"service": service, "lines": lines[:50], "duration_minutes": duration_minutes}
    except Exception as e:
        return {"error": str(e)}


def query_prometheus(promql: str) -> dict:
    params = urllib.parse.urlencode({"query": promql})
    try:
        data = _http_get(f"{PROMETHEUS_URL}/api/v1/query?{params}")
        results = data.get("data", {}).get("result", [])
        return {
            "promql": promql,
            "results": [
                {"metric": r["metric"], "value": r["value"][1]}
                for r in results
            ]
        }
    except Exception as e:
        return {"error": str(e)}


TOOL_MAP = {
    "get_alert_details": get_alert_details,
    "query_loki": query_loki,
    "query_prometheus": query_prometheus,
}

SYSTEM_PROMPT = """You are an SRE on-call assistant for CoverLine, a digital health insurance platform.

A Grafana alert has just fired. Your job is to:
1. Use get_alert_details to understand what alert fired and what service it affects.
2. Use query_loki to retrieve recent error logs from that service.
3. Use query_prometheus to check related metrics (error rate, latency, pod restarts) for the affected service.
4. Post a structured hypothesis.

Your final response must be a JSON object:
{
  "summary": "one sentence describing what is happening",
  "likely_cause": "one sentence root cause hypothesis",
  "evidence": ["log line or metric that supports the hypothesis", ...],
  "recommended_actions": ["action 1", "action 2"],
  "severity": "critical|high|medium|low"
}

Return ONLY the JSON object — no surrounding text."""


def investigate_alert(alert_name: str) -> str:
    messages = [{"role": "user", "content": f"Alert fired: {alert_name}. Investigate and post your hypothesis."}]

    for _ in range(8):  # max turns
        response = client.messages.create(
            model="claude-sonnet-4-6",
            max_tokens=1024,
            system=SYSTEM_PROMPT,
            tools=TOOLS,
            messages=messages,
        )

        if response.stop_reason == "end_turn":
            return next(b.text for b in response.content if hasattr(b, "text"))

        tool_results = []
        for block in response.content:
            if block.type == "tool_use":
                fn = TOOL_MAP[block.name]
                result = fn(**block.input)
                tool_results.append({
                    "type": "tool_result",
                    "tool_use_id": block.id,
                    "content": json.dumps(result),
                })

        messages.append({"role": "assistant", "content": response.content})
        messages.append({"role": "user", "content": tool_results})

    return json.dumps({"error": "Agent exceeded max turns without reaching a conclusion"})


def post_to_webhook(hypothesis: dict, alert_name: str):
    """Format the hypothesis for Slack and post it."""
    severity_emoji = {"critical": "🔴", "high": "🟠", "medium": "🟡", "low": "🟢"}.get(
        hypothesis.get("severity", "high"), "🟠"
    )
    text = (
        f"{severity_emoji} *On-call assistant — {alert_name}*\n\n"
        f"*Summary:* {hypothesis.get('summary', 'N/A')}\n"
        f"*Likely cause:* {hypothesis.get('likely_cause', 'N/A')}\n\n"
        f"*Evidence:*\n" + "\n".join(f"• {e}" for e in hypothesis.get("evidence", [])) + "\n\n"
        f"*Recommended actions:*\n" + "\n".join(f"• {a}" for a in hypothesis.get("recommended_actions", []))
    )
    payload = json.dumps({"text": text}).encode()
    req = urllib.request.Request(
        WEBHOOK_URL, data=payload,
        headers={"Content-Type": "application/json"}
    )
    urllib.request.urlopen(req, timeout=10)


class WebhookHandler(BaseHTTPRequestHandler):
    """Receive Grafana webhook calls and trigger the agent."""

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = json.loads(self.rfile.read(length)) if length else {}

        # Grafana sends alerts as a list under "alerts"
        for alert in body.get("alerts", [body]):
            alert_name = alert.get("labels", {}).get("alertname", "UnknownAlert")
            print(f"Received alert: {alert_name}")
            try:
                raw = investigate_alert(alert_name)
                hypothesis = json.loads(raw)
                print(json.dumps(hypothesis, indent=2))
                if WEBHOOK_URL:
                    post_to_webhook(hypothesis, alert_name)
            except Exception as e:
                print(f"Agent failed for {alert_name}: {e}")

        self.send_response(200)
        self.end_headers()

    def log_message(self, *args):
        pass  # suppress default access log noise


if __name__ == "__main__":
    import sys
    if len(sys.argv) > 1:
        # Direct invocation: python on_call_assistant.py HighErrorRate
        alert_name = sys.argv[1]
        raw = investigate_alert(alert_name)
        print(json.dumps(json.loads(raw), indent=2))
    else:
        # HTTP server mode for Grafana webhook
        port = int(os.environ.get("PORT", "8888"))
        print(f"Listening for Grafana webhooks on :{port}")
        HTTPServer(("", port), WebhookHandler).serve_forever()
```

### Deploy as a Kubernetes Deployment

Create `phase-12-genai/k8s/on-call-assistant.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: on-call-assistant
  namespace: default
  labels:
    app: on-call-assistant
spec:
  replicas: 1
  selector:
    matchLabels:
      app: on-call-assistant
  template:
    metadata:
      labels:
        app: on-call-assistant
    spec:
      containers:
        - name: on-call-assistant
          image: python:3.12-slim
          command: ["sh", "-c", "pip install anthropic -q && python /app/on_call_assistant.py"]
          ports:
            - containerPort: 8888
          env:
            - name: ANTHROPIC_API_KEY
              valueFrom:
                secretKeyRef:
                  name: anthropic-api-key
                  key: ANTHROPIC_API_KEY
            - name: GRAFANA_URL
              value: "http://kube-prometheus-stack-grafana.monitoring.svc.cluster.local"
            - name: LOKI_URL
              value: "http://loki.monitoring.svc.cluster.local:3100"
            - name: PROMETHEUS_URL
              value: "http://kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090"
            - name: ONCALL_WEBHOOK_URL
              valueFrom:
                secretKeyRef:
                  name: oncall-webhook-url
                  key: url
                  optional: true
          volumeMounts:
            - name: agent-code
              mountPath: /app
      volumes:
        - name: agent-code
          configMap:
            name: on-call-assistant-code
---
apiVersion: v1
kind: Service
metadata:
  name: on-call-assistant
  namespace: default
spec:
  selector:
    app: on-call-assistant
  ports:
    - port: 8888
      targetPort: 8888
```

Create the ConfigMap from the script and apply:

```bash
kubectl create configmap on-call-assistant-code \
  --from-file=on_call_assistant.py=phase-12-genai/on_call_assistant.py

kubectl apply -f phase-12-genai/k8s/on-call-assistant.yaml
```

Verify the pod is running:

```bash
kubectl get pods -l app=on-call-assistant
kubectl logs -l app=on-call-assistant
```

Expected log line:

```
Listening for Grafana webhooks on :8888
```

### Wire Grafana to the agent

1. Open Grafana: `kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80`
2. Navigate to **Alerting → Contact points → New contact point**
3. Set type to **Webhook**
4. URL: `http://on-call-assistant.default.svc.cluster.local:8888`
5. Click **Test** — Grafana sends a test payload and the agent runs immediately

### Test manually

Trigger the agent directly without waiting for a real alert:

```bash
kubectl exec -it \
  $(kubectl get pod -l app=on-call-assistant -o name | head -1) \
  -- python /app/on_call_assistant.py HighErrorRate
```

Expected output (formatted):

```json
{
  "summary": "coverline-backend error rate spiked to 14% over the last 10 minutes",
  "likely_cause": "Repeated database connection errors suggest PostgreSQL is refusing connections — likely exhausted connection pool",
  "evidence": [
    "ERROR [app.py:142] psycopg2.OperationalError: FATAL: remaining connection slots are reserved",
    "Prometheus: rate(http_requests_total{status=~'5..'}[5m]) = 0.14",
    "Prometheus: pg_stat_activity_count = 100 (at connection limit)"
  ],
  "recommended_actions": [
    "Check PostgreSQL max_connections: kubectl exec postgresql-0 -- psql -U coverline -c 'SHOW max_connections'",
    "Restart coverline-backend to release stale connections: kubectl rollout restart deployment/coverline-backend",
    "Consider adding PgBouncer as a connection pooler if this recurs"
  ],
  "severity": "high"
}
```

### Add the on-call assistant to the notification policy

1. In Grafana, go to **Alerting → Notification policies**
2. Edit the default policy (or create a new one for `severity=critical`)
3. Set the contact point to the webhook you created above
4. Save

From this point, every alert that fires in Grafana automatically triggers the agent. The hypothesis arrives in the incident channel within 15–30 seconds of the alert firing.

---

## Step 8 — Verify & Screenshot

### Summary verification commands

```bash
# Pushgateway running
kubectl get pods -n monitoring | grep pushgateway

# Airflow DAG visible
kubectl port-forward -n airflow svc/airflow-webserver 8080:8080
# Open http://localhost:8080 → DAGs → claims_triage

# Triage decisions in database
psql -h localhost -U coverline -d coverline \
  -c "SELECT decision, COUNT(*), ROUND(AVG(confidence)::numeric, 2) AS avg_confidence FROM claim_triage GROUP BY decision;"

# Metrics visible in Prometheus
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090
# Open http://localhost:9090 → query: llm_cost_usd

# Grafana dashboard loaded
kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80
# Open http://localhost:3000 → Dashboards → CoverLine — LLM Claims Triage
```

### Screenshots to take

| Screenshot | How to get it |
|---|---|
| Airflow DAG graph view — claims_triage run success | Airflow UI → DAGs → claims_triage → Graph |
| PostgreSQL triage results | Terminal output of the SELECT above |
| Prometheus target — pushgateway UP | Prometheus UI → Status → Targets |
| Grafana LLM dashboard — daily cost + decision distribution | Port-forward → Grafana → LLM Claims Triage dashboard |
| On-call assistant pod running | `kubectl get pods -l app=on-call-assistant` |
| On-call assistant JSON output | Terminal output of the manual trigger command |
| Grafana contact point — webhook wired to on-call assistant | Grafana → Alerting → Contact points |

---

## Troubleshooting

### Agent returns malformed JSON

**Cause:** The model occasionally wraps the JSON in a markdown code block or adds a preamble sentence when the prompt is ambiguous.

**Fix:** Update the system prompt to be more explicit: *"Your final response must be a single JSON object and nothing else — no markdown, no explanation."* Alternatively, add a post-processing step that extracts JSON from the response text:

```python
import re

def extract_json(text: str) -> dict:
    match = re.search(r'\{.*\}', text, re.DOTALL)
    if match:
        return json.loads(match.group())
    raise ValueError(f"No JSON found in model response: {text[:200]}")
```

### Pushgateway metrics not appearing in Prometheus

**Cause:** The ServiceMonitor is not matching the Pushgateway service, or the Prometheus operator is not watching the `monitoring` namespace for ServiceMonitors from the Pushgateway chart.

**Check the ServiceMonitor label:**
```bash
kubectl get servicemonitor -n monitoring prometheus-pushgateway -o yaml | grep -A 5 matchLabels
```

The `release` label must match the kube-prometheus-stack release name (typically `kube-prometheus-stack`). If it does not match:
```bash
helm upgrade prometheus-pushgateway prometheus-community/prometheus-pushgateway \
  --namespace monitoring \
  --set serviceMonitor.enabled=true \
  --set serviceMonitor.additionalLabels.release=kube-prometheus-stack
```

### Airflow task fails with `ANTHROPIC_API_KEY not set`

**Cause:** The secret was created but the environment variable is not injected into the Airflow pods.

**Verify the secret exists:**
```bash
kubectl get secret anthropic-api-key -n airflow
```

**Check the running pod's environment:**
```bash
kubectl exec -n airflow \
  $(kubectl get pod -n airflow -l component=worker -o name | head -1) \
  -- env | grep ANTHROPIC
```

If the variable is missing, the Helm upgrade did not propagate. Check `helm get values airflow -n airflow` and confirm the `env` block is present.

### On-call assistant returns `No active alert named '...'`

**Cause:** The agent queries the Grafana Alertmanager API for currently *firing* alerts. If you trigger a test from the Grafana contact point UI, the test payload uses a synthetic alert name that does not match any real rule.

**Fix for testing:** Pass the alert name directly via CLI rather than relying on the Grafana test button:

```bash
kubectl exec -it $(kubectl get pod -l app=on-call-assistant -o name | head -1) \
  -- python /app/on_call_assistant.py HighErrorRate
```

For the alert name to resolve against the Alertmanager API, an alert rule with `alertname=HighErrorRate` must actually be firing. Simulate one by temporarily lowering a threshold:

```bash
# Temporarily lower the error rate threshold to fire immediately
kubectl edit prometheusrule -n monitoring kube-prometheus-stack-kubernetes-apps
# Change expr threshold, wait 1 minute for the rule to fire, then test the agent
```

### On-call assistant pod crashes on startup

**Cause:** The `anthropic` package takes ~20 seconds to install via `pip` at startup. During that window, if Kubernetes sends a readiness probe, the pod restarts before the server is up.

**Fix:** Remove the inline `pip install` pattern and build a proper Docker image instead:

```dockerfile
FROM python:3.12-slim
RUN pip install anthropic --no-cache-dir
COPY on_call_assistant.py /app/on_call_assistant.py
CMD ["python", "/app/on_call_assistant.py"]
```

Build, push to Artifact Registry, and update the Deployment image reference. This also eliminates the ConfigMap volume mount.

### Token costs higher than expected

**Cause:** Agentic loops with tool use accumulate tokens across every turn — the full conversation history (including tool results) is re-sent to the model on each API call.

**Diagnose:** Add logging to print `len(messages)` and total token counts after each turn. A 3-tool-call triage run should consume roughly 400–600 input tokens. If you see 2,000+ tokens, the message history is growing unexpectedly — check for duplicate tool result entries.

**Fix:** Cap the conversation to a maximum number of turns (typically 5–6 for this use case) and raise an error if the limit is reached rather than continuing indefinitely.

---

## Production Considerations

### 1. Validate structured output before writing to the database

The model's JSON output should be validated against a schema before any database write. A malformed or out-of-range `confidence` value, or an unrecognised `decision` string, should fail loudly rather than silently writing corrupt data to the claims table. Use `pydantic` for this:

```python
from pydantic import BaseModel, confloat
from typing import Literal

class TriageDecision(BaseModel):
    decision: Literal["approve", "review", "reject"]
    confidence: confloat(ge=0.0, le=1.0)
    reason: str
```

### 2. Add a cost circuit breaker

Agentic loops can run indefinitely if a tool call always returns data that prompts the model to call another tool. Set a maximum turn limit and a per-run token budget. If either is exceeded, cancel the run, write a `review` decision (the safe fallback for uncertain cases), and emit an alert metric:

```python
MAX_TURNS = 6
MAX_TOKENS_PER_CLAIM = 2000

if turn_count > MAX_TURNS or total_tokens > MAX_TOKENS_PER_CLAIM:
    raise RuntimeError(f"Agent exceeded limits — claim {claim_id} sent to manual review")
```

### 3. Version your prompts alongside your code

The system prompt is a first-class artefact. A prompt change can change decision distribution as significantly as a code change. Store prompts in version control, log the prompt version alongside each triage decision, and treat prompt changes like code changes: review, test on a held-out claims dataset, and document the expected change in decision distribution before deploying.

### 4. Audit trail is non-negotiable for regulated workloads

Health insurance claims are subject to regulatory audit requirements. Every triage decision must be traceable: which model version, which prompt version, which input data, and what the output was. The `claim_triage` table already captures `model`, `input_tokens`, and `output_tokens`. Extend it with a `prompt_version` column and log the full raw API request and response to an append-only audit log (GCS + BigQuery works well). Never delete or update audit rows.

### 5. Human-in-the-loop for low-confidence decisions

The agent assigns a `confidence` score. Decisions with `confidence < 0.75` should be automatically routed to a human reviewer rather than auto-committed. This is not a limitation of the model — it is a deliberate governance decision. Configure the Grafana alert to fire if the fraction of `review` decisions exceeds a threshold, which may indicate the model is encountering claim types it was not designed to handle.

---

## ADRs

- `docs/decisions/adr-023-llm-provider.md` — Why Claude (Anthropic) over OpenAI, Gemini, self-hosted Ollama
- `docs/decisions/adr-024-agentic-framework.md` — Why raw Anthropic SDK over LangChain, LlamaIndex, CrewAI
