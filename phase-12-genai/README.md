# Phase 12 — GenAI & Agentic Platform

> **GenAI concepts introduced:** Anthropic SDK tool use, agentic loops, Prometheus Pushgateway, structured output validation | **Builds on:** Phase 6 observability, Phase 9 data platform

[📝 Take the quiz](https://wb-platform-engineering-lab.github.io/platform-engineering-lab-gke/phase-12-genai/quiz.html)

---

## Concepts introduced

| Concept | What it does | Why we need it |
|---|---|---|
| **Tool use** | The model calls Python functions to query the database, then reasons over the results | The agent can answer "is this claim covered?" by looking up real policy data — not by guessing |
| **Agentic loop** | The model calls tools and receives results in a conversation until it reaches a final answer | Claims triage requires 3–5 sequential data lookups — a single prompt cannot do this |
| **Structured output** | The model returns a JSON object with a fixed schema (`decision`, `confidence`, `reason`) | Production systems need machine-readable decisions, not paragraphs |
| **Prometheus Pushgateway** | Receives metrics pushed by short-lived batch jobs and holds them for Prometheus to scrape | The triage agent runs as a job (not a server) — it cannot expose a `/metrics` endpoint |
| **Airflow DAG** | Wraps the agent in a scheduled pipeline with retry logic and XCom state passing | The agent needs to run daily, handle failures gracefully, and integrate with the existing data platform |

---

## The problem

> *CoverLine — Series D, 3,000,000+ covered members.*
>
> The claims operations team is drowning. With 3 million members, over 8,000 claims are submitted every day. Manual triage — a human reviewer reads the claim, checks the member's policy, cross-references their claim history, and decides whether to approve, flag for review, or reject — takes 48 to 72 hours per claim and costs €4 in reviewer time. At scale, that is €32,000 per day in labour, and the backlog is growing faster than the team can hire.
>
> The medical director proposed an AI triage assistant. An agentic system that reads incoming claims, queries the member's policy and history from the database, decides whether to auto-approve, flag for review, or reject, and writes a structured explanation to the database. Not a chatbot — a production workflow that runs on a schedule, writes decisions to PostgreSQL, and emits metrics to Prometheus.
>
> The CTO's directive: *"I want LLM cost on the same Grafana dashboard as cluster cost. I want the p95 response time, the daily token spend, and the decision distribution before I approve this for production. And I want a circuit breaker — if the model starts making unusual decisions at scale, I need to know before the claims team does."*

---

## Architecture

```
Airflow DAG (daily 06:00 UTC)
    └── PythonOperator → claims_triage_agent.py
            │
            ├── Tool: query_claim(claim_id)         → PostgreSQL
            ├── Tool: get_policy(member_id)          → PostgreSQL
            └── Tool: get_claim_history(member_id)   → PostgreSQL
                    │
                    └── Claude API (claude-sonnet-4-6)
                            │
                            ├── Returns: {"decision": "approve"|"review"|"reject",
                            │             "confidence": 0.0-1.0, "reason": "..."}
                            │
                            ├── Write result → PostgreSQL (claim_triage table)
                            └── Push metrics → Prometheus Pushgateway
                                    └── Prometheus scrapes → Grafana LLM dashboard

On-call assistant (runs as a Deployment):
    └── Grafana webhook → on_call_assistant.py
            ├── Tool: get_alert_details(alert_name)  → Grafana Alerting API
            ├── Tool: query_loki(service, duration)  → Loki HTTP API
            └── Tool: query_prometheus(promql)       → Prometheus HTTP API
                    └── Posts hypothesis → Slack webhook
```

---

## Repository structure

```
phase-12-genai/
├── claims_triage_agent.py    ← Agent with tool use + PostgreSQL reads/writes
├── weekly_summary_agent.py   ← BigQuery summary → webhook
├── on_call_assistant.py      ← Alert investigation agent + HTTP server
├── dags/
│   └── claims_triage_dag.py  ← Airflow DAG wrapping the triage agent
└── k8s/
    └── on-call-assistant.yaml ← Deployment + Service for the on-call assistant
```

---

## Prerequisites

Phases 1 through 10 complete. Phase 12 builds on the PostgreSQL database (Phase 3), the Airflow data platform (Phase 9), and the Prometheus/Grafana observability stack (Phase 6).

```bash
bash bootstrap.sh --phase 9
kubectl get pods -n monitoring      # Prometheus + Grafana
kubectl get pods -n airflow         # Airflow scheduler + webserver
kubectl get pods                    # PostgreSQL in default namespace
```

Install the Python dependencies for local testing:

```bash
pip install anthropic psycopg2-binary prometheus-client
export ANTHROPIC_API_KEY="your-api-key-here"
```

> **Cost note:** A typical claims triage run (~500 input tokens + ~200 output tokens) costs ~$0.005 per claim at Sonnet pricing ($3/$15 per 1M tokens). Testing with 10–20 seeded claims costs under $0.10.

---

## Architecture Decision Records

- `docs/decisions/adr-047-llm-provider-anthropic.md` — Why Claude (Anthropic) over OpenAI, Gemini, or self-hosted Ollama
- `docs/decisions/adr-048-raw-sdk-over-langchain.md` — Why raw Anthropic SDK over LangChain, LlamaIndex, or CrewAI for regulated claims workflows

---

## Challenge 1 — Seed the database with test claims

Before building the agent, seed PostgreSQL with realistic test data. The triage agent needs a `claims` table, a `policies` table, and a `claim_triage` table to read and write.

### Step 1: Port-forward PostgreSQL

```bash
kubectl port-forward svc/postgresql 5432:5432 &
```

### Step 2: Create the schema and seed test data

```bash
psql -h localhost -U coverline -d coverline -c "
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

CREATE TABLE IF NOT EXISTS policies (
    member_id        INTEGER PRIMARY KEY,
    plan_type        VARCHAR(50) NOT NULL,
    deductible_eur   NUMERIC(10,2) NOT NULL,
    annual_limit_eur NUMERIC(10,2) NOT NULL,
    covered_services TEXT[],
    effective_date   DATE NOT NULL
);

CREATE TABLE IF NOT EXISTS claim_triage (
    triage_id     SERIAL PRIMARY KEY,
    claim_id      INTEGER REFERENCES claims(claim_id),
    decision      VARCHAR(20) NOT NULL,
    confidence    NUMERIC(4,3) NOT NULL,
    reason        TEXT NOT NULL,
    model         VARCHAR(50) NOT NULL,
    input_tokens  INTEGER,
    output_tokens INTEGER,
    latency_ms    INTEGER,
    created_at    TIMESTAMP DEFAULT NOW()
);

INSERT INTO policies VALUES
    (1001, 'standard',  500.00, 10000.00, ARRAY['consultation','specialist','emergency','prescription'], '2024-01-01'),
    (1002, 'premium',   200.00, 25000.00, ARRAY['consultation','specialist','emergency','prescription','dental','physio'], '2024-01-01'),
    (1003, 'basic',    1000.00,  5000.00, ARRAY['consultation','emergency'], '2024-01-01');

INSERT INTO claims (member_id, claim_date, claim_type, amount_eur, description, status) VALUES
    (1001, NOW()::DATE, 'specialist',   450.00, 'Cardiology consultation + ECG', 'pending'),
    (1001, NOW()::DATE, 'prescription', 120.00, 'Monthly diabetes medication', 'pending'),
    (1002, NOW()::DATE, 'dental',       800.00, 'Root canal treatment', 'pending'),
    (1003, NOW()::DATE, 'specialist',   350.00, 'Physiotherapy — 5 sessions', 'pending'),
    (1003, NOW()::DATE, 'prescription',  45.00, 'Antibiotic course', 'pending');
"
```

### Step 3: Verify the seed data

```bash
psql -h localhost -U coverline -d coverline -c "
SELECT c.claim_id, c.member_id, c.claim_type, c.amount_eur, p.plan_type
FROM claims c JOIN policies p ON c.member_id = p.member_id
WHERE c.status = 'pending';
"
```

---

## Challenge 2 — Build and test the claims triage agent

### Step 1: Review the agent structure

The agent at `phase-12-genai/claims_triage_agent.py` follows a fixed pattern:

1. Send a message to the model with a tool list and a system prompt
2. If the model returns `stop_reason == "tool_use"`, execute the requested tools and send back the results
3. Repeat until `stop_reason == "end_turn"`, then parse the final JSON decision

Three tools are defined:
- `query_claim(claim_id)` — retrieves claim details from PostgreSQL
- `get_policy(member_id)` — retrieves the member's coverage
- `get_claim_history(member_id)` — retrieves recent claim history for anomaly detection

The system prompt enforces a fixed decision schema: `{"decision": "approve"|"review"|"reject", "confidence": 0.0-1.0, "reason": "one sentence"}`.

### Step 2: Run the agent locally

With the port-forward to PostgreSQL still active:

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
  → review  (confidence=0.71) | 498+201 tokens | 2489ms
Triaging claim 5...
  → approve (confidence=0.94) | 463+138 tokens | 1876ms
```

> Claim 4 (physiotherapy for a `basic` plan member) is expected to receive `review` — physiotherapy is not in the basic plan's covered services, but the amount is within limits. The model should flag this for human review rather than auto-rejecting.

### Step 3: Verify decisions were written to the database

```bash
psql -h localhost -U coverline -d coverline -c "
SELECT c.claim_type, c.amount_eur, ct.decision, ct.confidence, ct.reason
FROM claims c JOIN claim_triage ct ON c.claim_id = ct.claim_id
ORDER BY ct.created_at DESC;
"
```

---

## Challenge 3 — Install the Prometheus Pushgateway

The triage agent runs as a short-lived batch job — it exits when done and cannot expose a `/metrics` endpoint. The Pushgateway receives metrics pushed by the agent and holds them until the next Prometheus scrape.

### Step 1: Install via Helm

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

helm install prometheus-pushgateway prometheus-community/prometheus-pushgateway \
  --namespace monitoring \
  --set serviceMonitor.enabled=true \
  --set serviceMonitor.additionalLabels.release=kube-prometheus-stack
```

The `serviceMonitor.additionalLabels.release=kube-prometheus-stack` label is required — without it the Prometheus operator does not pick up the ServiceMonitor.

### Step 2: Verify Prometheus can scrape the Pushgateway

```bash
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090
```

Open `http://localhost:9090/targets` and confirm `pushgateway` appears with state `UP`.

### Step 3: Confirm the metrics appear after a triage run

After running the agent locally:

```
# In the Prometheus UI (http://localhost:9090)
llm_cost_usd
llm_latency_ms
llm_input_tokens_total
llm_output_tokens_total
```

---

## Challenge 4 — Deploy the Airflow DAG

The Airflow DAG wraps the agent in a scheduled pipeline: a `fetch_pending_claims` task queries PostgreSQL and passes claim IDs via XCom, then a `run_triage` task calls `run_batch()` on those IDs.

### Step 1: Review the DAG structure

`phase-12-genai/dags/claims_triage_dag.py` schedules at `0 6 * * *` (06:00 UTC daily). The two tasks are:
- `fetch_pending_claims` — queries PostgreSQL for `status = 'pending'`, pushes IDs to XCom
- `run_triage` — pulls IDs from XCom, calls `run_batch(claim_ids)`

### Step 2: Store the API key as a Kubernetes secret

```bash
kubectl create secret generic anthropic-api-key \
  --from-literal=ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" \
  --namespace airflow
```

Inject the secret into Airflow pods:

```bash
helm upgrade airflow apache-airflow/airflow \
  --namespace airflow \
  --reuse-values \
  --set "env[0].name=ANTHROPIC_API_KEY" \
  --set "env[0].valueFrom.secretKeyRef.name=anthropic-api-key" \
  --set "env[0].valueFrom.secretKeyRef.key=ANTHROPIC_API_KEY"
```

### Step 3: Copy the DAG and agent into Airflow

```bash
SCHEDULER=$(kubectl get pod -n airflow -l component=scheduler -o name | head -1 | cut -d/ -f2)

kubectl cp phase-12-genai/claims_triage_agent.py \
  airflow/${SCHEDULER}:/opt/airflow/dags/claims_triage_agent.py

kubectl cp phase-12-genai/dags/claims_triage_dag.py \
  airflow/${SCHEDULER}:/opt/airflow/dags/claims_triage_dag.py
```

### Step 4: Trigger and verify

```bash
kubectl port-forward -n airflow svc/airflow-webserver 8080:8080 &
```

Open `http://localhost:8080` → **DAGs → claims_triage** → **Trigger DAG**. Watch the task logs in the Airflow UI — each log line shows the per-claim token counts and decision.

---

## Challenge 5 — Build the LLM observability dashboard

The triage agent pushes four metrics per claim to the Pushgateway: `llm_input_tokens_total`, `llm_output_tokens_total`, `llm_latency_ms`, and `llm_cost_usd`.

### Step 1: Import the dashboard into Grafana

```bash
kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80
```

Open `http://localhost:3000` → **Dashboards → Import → Paste JSON** and import the dashboard from `phase-12-genai/dashboards/llm-claims-triage.json` (or create manually with the panels below).

### Step 2: Key panels and their PromQL

| Panel | Type | PromQL |
|---|---|---|
| Daily cost (USD) | stat | `sum(llm_cost_usd)` |
| Agent latency p95 (ms) | stat | `histogram_quantile(0.95, sum(rate(llm_latency_ms[1h])) by (le))` |
| Decision distribution | piechart | `count by (decision) (llm_cost_usd)` |
| Cost over time | timeseries | `sum(llm_cost_usd) by (decision)` |

### Step 3: Verify the dashboard after a triage run

After triggering the DAG or running the agent locally, the dashboard should show:
- Non-zero daily cost
- A decision distribution pie chart (mostly `approve`, with some `review`)
- A latency stat in the 1500–3000 ms range per claim

### Step 4: Add a cost anomaly alert

Create a PrometheusRule to fire if daily LLM spend exceeds a threshold:

```bash
kubectl apply -f - <<'EOF'
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: llm-cost-anomaly
  namespace: monitoring
  labels:
    release: kube-prometheus-stack
spec:
  groups:
    - name: llm-cost
      rules:
        - alert: LLMDailyCostHigh
          expr: sum(llm_cost_usd) > 50
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "LLM daily cost exceeds $50 — check for runaway batch"
EOF
```

---

## Challenge 6 — Deploy the weekly summary agent

The weekly summary agent replaces the manual CSV export from Phase 9. It queries BigQuery for weekly claims trends and posts a structured report to a webhook.

### Step 1: Review the agent

`phase-12-genai/weekly_summary_agent.py` uses a single tool: `query_claims_summary(weeks_back)` — which queries BigQuery for total claims, total amount, and decision breakdown per claim type for the specified period.

The model writes the results as a concise executive summary formatted for Slack.

### Step 2: Set environment variables and test locally

```bash
export BQ_PROJECT="platform-eng-lab-will"
export BQ_DATASET="coverline"
export SUMMARY_WEBHOOK_URL="https://hooks.slack.com/services/your-webhook-url"

python phase-12-genai/weekly_summary_agent.py
```

Expected output: a short paragraph summarising last week's claims volume, total amount processed, and decision distribution — ready to post directly to a Slack channel.

### Step 3: Add the weekly DAG to Airflow

Wrap the agent in an Airflow DAG scheduled at `0 8 * * 1` (Monday 08:00 UTC) following the same pattern as Challenge 4. The task calls `run_summary_agent()` and posts the result to the webhook.

---

## Challenge 7 — Deploy the on-call assistant

The on-call assistant fires when a Grafana alert triggers. It queries the alert state, recent logs from Loki, and related metrics from Prometheus, then posts a structured root cause hypothesis to a webhook — before the on-call engineer has finished reading the PagerDuty notification.

### Step 1: Create the Kubernetes secret for the API key

```bash
kubectl create secret generic anthropic-api-key \
  --from-literal=ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY"
```

### Step 2: Deploy the assistant

```bash
kubectl create configmap on-call-assistant-code \
  --from-file=on_call_assistant.py=phase-12-genai/on_call_assistant.py

kubectl apply -f phase-12-genai/k8s/on-call-assistant.yaml
```

Verify:

```bash
kubectl get pods -l app=on-call-assistant
kubectl logs -l app=on-call-assistant
```

Expected log line: `Listening for Grafana webhooks on :8888`

### Step 3: Wire Grafana to the assistant

1. `kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80`
2. Navigate to **Alerting → Contact points → New contact point**
3. Type: **Webhook**
4. URL: `http://on-call-assistant.default.svc.cluster.local:8888`
5. Click **Test**

### Step 4: Test the agent manually

Trigger the assistant directly without waiting for a real alert:

```bash
kubectl exec -it \
  $(kubectl get pod -l app=on-call-assistant -o name | head -1) \
  -- python /app/on_call_assistant.py HighErrorRate
```

Expected output:

```json
{
  "summary": "coverline-backend error rate spiked to 14% over the last 10 minutes",
  "likely_cause": "Repeated database connection errors suggest PostgreSQL is refusing connections",
  "evidence": [
    "ERROR psycopg2.OperationalError: FATAL: remaining connection slots are reserved",
    "Prometheus: rate(http_requests_total{status=~'5..'}[5m]) = 0.14",
    "Prometheus: pg_stat_activity_count = 100 (at connection limit)"
  ],
  "recommended_actions": [
    "Check PostgreSQL max_connections: kubectl exec postgresql-0 -- psql -U coverline -c 'SHOW max_connections'",
    "Restart coverline-backend to release stale connections",
    "Consider adding PgBouncer as a connection pooler"
  ],
  "severity": "high"
}
```

### Step 5: Add the assistant to the Grafana notification policy

1. **Alerting → Notification policies → Edit default policy**
2. Set contact point to the webhook created in Step 3
3. Save

From this point, every alert firing in Grafana automatically triggers the agent. The hypothesis arrives in the incident channel within 15–30 seconds of the alert firing.

---

## Teardown

```bash
# On-call assistant
kubectl delete -f phase-12-genai/k8s/
kubectl delete configmap on-call-assistant-code
kubectl delete secret anthropic-api-key

# Pushgateway
helm uninstall prometheus-pushgateway -n monitoring

# Airflow DAGs (remove from scheduler pod)
SCHEDULER=$(kubectl get pod -n airflow -l component=scheduler -o name | head -1 | cut -d/ -f2)
kubectl exec -n airflow ${SCHEDULER} -- rm /opt/airflow/dags/claims_triage_agent.py
kubectl exec -n airflow ${SCHEDULER} -- rm /opt/airflow/dags/claims_triage_dag.py

# Database tables
kubectl port-forward svc/postgresql 5432:5432 &
psql -h localhost -U coverline -d coverline -c "DROP TABLE IF EXISTS claim_triage, claims, policies;"
```

---

## Cost breakdown

| Resource | $/day |
|---|---|
| GKE cluster (Phase 1) | ~$0.66 |
| Claude API — test run (10 claims) | ~$0.05 |
| Claude API — production (8,000 claims/day) | ~$40.00 |
| Pushgateway pod | included in node cost |
| **Phase 12 cluster cost** | **~$0.66** |

> Production API cost is ~$40/day at current Sonnet pricing, replacing €32,000/day in manual reviewer labour. The ROI is approximately 800×. Monitor daily spend with the `LLMDailyCostHigh` alert and the cost dashboard from Challenge 5.

---

## GenAI concept: agentic loops vs single-shot prompts

A **single-shot prompt** sends all context in one message and expects the answer directly. This works when the context is static and fits in the prompt: "summarise this paragraph," "classify this email."

An **agentic loop** is needed when the model must gather information before it can answer — and does not know which information it needs until it starts looking. Claims triage is a canonical example: the model needs to know what the claim is, what the policy covers, and whether there are anomalies in claim history. It cannot know which member's policy to look up until it reads the claim. It cannot check claim history until it knows the member ID. The three data lookups must happen in sequence, driven by what the model discovers at each step.

The loop structure is simple:
1. Send a message with a tool list
2. If the model returns tool calls, execute them and add the results to the conversation
3. Repeat until the model returns a final answer with no tool calls

The `stop_reason` field controls the loop: `tool_use` means continue, `end_turn` means the model has enough information to answer.

The key design decisions for production agentic loops:
- **Max turns**: cap the loop to prevent runaway cost if a tool always returns unexpected data
- **Structured output**: use a fixed JSON schema so the final answer is machine-readable
- **Schema validation**: validate the output before writing to the database (use `pydantic`)
- **Audit trail**: log every turn — which tools were called, what they returned, and what the model decided

---

## Production considerations

### 1. Validate structured output before writing to the database

```python
from pydantic import BaseModel, confloat
from typing import Literal

class TriageDecision(BaseModel):
    decision: Literal["approve", "review", "reject"]
    confidence: confloat(ge=0.0, le=1.0)
    reason: str
```

A malformed `confidence` value or unrecognised `decision` string should fail loudly rather than silently writing corrupt data.

### 2. Set a cost circuit breaker

Agentic loops accumulate tokens across every turn — the full conversation history is re-sent to the model on each call. Cap both turn count and per-claim token budget:

```python
MAX_TURNS = 6
MAX_TOKENS_PER_CLAIM = 2000

if turn_count > MAX_TURNS or total_tokens > MAX_TOKENS_PER_CLAIM:
    raise RuntimeError(f"Agent exceeded limits — claim {claim_id} sent to manual review")
```

### 3. Version your prompts alongside your code

The system prompt is a first-class artefact. A prompt change can shift decision distribution as significantly as a code change. Store prompts in version control, log the prompt version in the `claim_triage` table, and treat prompt changes like code changes: review, test on a held-out claims dataset, and document the expected change in decision distribution before deploying.

### 4. Audit trail is non-negotiable for regulated workloads

Health insurance claims are subject to regulatory audit requirements. Every triage decision must be traceable: which model version, which prompt version, which input data, and what the output was. Extend the `claim_triage` table with a `prompt_version` column and log the full raw API request and response to an append-only audit log (GCS + BigQuery works well). Never delete or update audit rows.

### 5. Human-in-the-loop for low-confidence decisions

The agent assigns a `confidence` score. Decisions with `confidence < 0.75` should be automatically routed to a human reviewer rather than auto-committed. This is not a limitation of the model — it is a deliberate governance decision. Configure the `LLMHighReviewRate` Grafana alert to fire if the fraction of `review` decisions exceeds 20%, which indicates the model is encountering claim types outside its training distribution.

### 6. Build a proper Docker image for the on-call assistant

The `on-call-assistant.yaml` installs `anthropic` via `pip` at pod startup — this takes ~20 seconds and causes readiness probe failures. Build a proper image:

```dockerfile
FROM python:3.12-slim
RUN pip install anthropic --no-cache-dir
COPY on_call_assistant.py /app/on_call_assistant.py
CMD ["python", "/app/on_call_assistant.py"]
```

---

## Outcome

CoverLine now has an AI-powered triage assistant in production. The claims backlog that was growing at 8,000 claims/day is now processed automatically each morning: straightforward claims are approved, borderline cases are flagged for human review, and clearly uncovered claims are rejected — all with a written reason and a confidence score. The decision distribution and daily API cost are visible on the same Grafana dashboard as cluster cost. When an alert fires at 2 AM, the on-call engineer receives a structured hypothesis in their incident channel before they have finished reading the page. The human reviewers now focus on the 15–20% of claims that genuinely need judgment — not on the 80% that were always going to be approved.

---

[Back to main README](../README.md) | [Back to Phase 11 — Capstone](../phase-11-capstone/README.md)
