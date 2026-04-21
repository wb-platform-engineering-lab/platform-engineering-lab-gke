"""
Phase 12 — Claims Triage Agent
Anthropic SDK tool use loop + PostgreSQL reads/writes + Prometheus Pushgateway metrics.
"""

import json
import os
import re
import time
from typing import Literal

import anthropic
import psycopg2
from prometheus_client import CollectorRegistry, Gauge, push_to_gateway
from pydantic import BaseModel, field_validator

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

DB_HOST = os.environ.get("DB_HOST", "localhost")
DB_NAME = os.environ.get("DB_NAME", "coverline")
DB_USER = os.environ.get("DB_USER", "coverline")
DB_PASSWORD = os.environ.get("DB_PASSWORD", "coverline")

PUSHGATEWAY_URL = os.environ.get("PUSHGATEWAY_URL", "http://prometheus-pushgateway.monitoring.svc.cluster.local:9091")

MODEL = "claude-sonnet-4-6"
MAX_TURNS = 6
MAX_TOKENS_PER_RUN = 8000

SYSTEM_PROMPT = """You are an insurance claims triage assistant for CoverLine.

Your job is to evaluate health insurance claims and decide whether to approve, review, or reject them.
Use the available tools to:
1. Retrieve the claim details (query_claim)
2. Look up the member's insurance policy (get_policy)
3. Check the member's recent claim history (get_claim_history)

After gathering information, output ONLY a raw JSON object — no prose, no markdown, no explanation before or after. Your entire response must be parseable by json.loads().

Schema:
{"decision": "approve"|"review"|"reject", "confidence": 0.0-1.0, "reason": "one sentence"}

Decision rules:
- approve: claim type is in covered_services AND amount is within annual_limit_eur
- review: borderline coverage, unusually high amount, or suspicious duplicate pattern
- reject: claim type is NOT in covered_services

Output ONLY the JSON object. Nothing else."""

# ---------------------------------------------------------------------------
# Pydantic model (Challenge 6, Step 1)
# ---------------------------------------------------------------------------


class TriageDecision(BaseModel):
    decision: Literal["approve", "review", "reject"]
    confidence: float
    reason: str

    @field_validator("confidence")
    @classmethod
    def confidence_in_range(cls, v: float) -> float:
        if not 0.0 <= v <= 1.0:
            raise ValueError(f"confidence {v} outside [0, 1]")
        return v


# ---------------------------------------------------------------------------
# Database helpers
# ---------------------------------------------------------------------------


def _connect() -> psycopg2.extensions.connection:
    return psycopg2.connect(
        host=DB_HOST, dbname=DB_NAME, user=DB_USER, password=DB_PASSWORD
    )


def sanitise_description(text: str) -> str:
    """Remove common prompt injection patterns from user-supplied text (Challenge 6, Step 4)."""
    if not text:
        return ""
    text = text[:500]
    text = re.sub(r"(?i)(ignore|forget|disregard).{0,30}(instruction|prompt|above)", "", text)
    return text.strip()


def query_claim(claim_id: int) -> dict:
    """Tool: retrieve a claim record by claim ID."""
    conn = _connect()
    try:
        cur = conn.cursor()
        cur.execute(
            "SELECT claim_id, member_id, claim_date, claim_type, amount_eur, description, status "
            "FROM claims WHERE claim_id = %s",
            (claim_id,),
        )
        row = cur.fetchone()
        if not row:
            return {"error": f"No claim found with id={claim_id}"}
        return {
            "claim_id": row[0],
            "member_id": row[1],
            "claim_date": str(row[2]),
            "claim_type": row[3],
            "amount_eur": float(row[4]),
            "description": sanitise_description(row[5]),
            "status": row[6],
        }
    finally:
        conn.close()


def get_policy(member_id: int) -> dict:
    """Tool: retrieve a member's insurance policy including covered services."""
    conn = _connect()
    try:
        cur = conn.cursor()
        cur.execute(
            "SELECT member_id, plan_type, deductible_eur, annual_limit_eur, covered_services "
            "FROM policies WHERE member_id = %s",
            (member_id,),
        )
        row = cur.fetchone()
        if not row:
            return {"error": f"No policy found for member_id={member_id}"}
        return {
            "member_id": row[0],
            "plan_type": row[1],
            "deductible_eur": float(row[2]),
            "annual_limit_eur": float(row[3]),
            "covered_services": list(row[4]) if row[4] else [],
        }
    finally:
        conn.close()


def get_claim_history(member_id: int) -> dict:
    """Tool: retrieve a member's recent claims history to check for duplicates."""
    conn = _connect()
    try:
        cur = conn.cursor()
        cur.execute(
            "SELECT claim_id, claim_date, claim_type, amount_eur, status "
            "FROM claims WHERE member_id = %s ORDER BY claim_date DESC LIMIT 10",
            (member_id,),
        )
        rows = cur.fetchall()
        return {
            "member_id": member_id,
            "recent_claims": [
                {
                    "claim_id": r[0],
                    "claim_date": str(r[1]),
                    "claim_type": r[2],
                    "amount_eur": float(r[3]),
                    "status": r[4],
                }
                for r in rows
            ],
        }
    finally:
        conn.close()


TOOL_MAP = {
    "query_claim": query_claim,
    "get_policy": get_policy,
    "get_claim_history": get_claim_history,
}

TOOLS = [
    {
        "name": "query_claim",
        "description": "Retrieve a claim record by claim ID.",
        "input_schema": {
            "type": "object",
            "properties": {"claim_id": {"type": "integer"}},
            "required": ["claim_id"],
        },
    },
    {
        "name": "get_policy",
        "description": "Retrieve a member's insurance policy including covered services.",
        "input_schema": {
            "type": "object",
            "properties": {"member_id": {"type": "integer"}},
            "required": ["member_id"],
        },
    },
    {
        "name": "get_claim_history",
        "description": "Retrieve a member's recent claims history to check for duplicates.",
        "input_schema": {
            "type": "object",
            "properties": {"member_id": {"type": "integer"}},
            "required": ["member_id"],
        },
    },
]


# ---------------------------------------------------------------------------
# Agentic loop
# ---------------------------------------------------------------------------


def triage_claim(claim_id: int) -> tuple[TriageDecision, dict]:
    """
    Run the agentic triage loop for a single claim.
    Returns (TriageDecision, usage_stats).
    Raises RuntimeError if the circuit breaker trips.
    """
    client = anthropic.Anthropic()

    messages = [
        {"role": "user", "content": f"Please triage claim ID {claim_id}."}
    ]

    total_input_tokens = 0
    total_output_tokens = 0
    turn = 0
    start_ms = time.time() * 1000

    while True:
        turn += 1

        # Circuit breaker (Challenge 6, Step 2)
        if turn > MAX_TURNS or (total_input_tokens + total_output_tokens) > MAX_TOKENS_PER_RUN:
            registry = CollectorRegistry()
            Gauge(
                "llm_circuit_breaker_total",
                "Circuit breaker trips",
                registry=registry,
            ).set(1)
            try:
                push_to_gateway(PUSHGATEWAY_URL, job="claims_triage", registry=registry)
            except Exception:
                pass
            raise RuntimeError(
                f"Claim {claim_id} exceeded limits (turns={turn}, "
                f"tokens={total_input_tokens + total_output_tokens}) "
                "— routed to manual review"
            )

        response = client.messages.create(
            model=MODEL,
            max_tokens=1024,
            system=SYSTEM_PROMPT,
            tools=TOOLS,
            messages=messages,
        )

        total_input_tokens += response.usage.input_tokens
        total_output_tokens += response.usage.output_tokens

        if response.stop_reason == "end_turn":
            # Extract the JSON text block
            text_block = next(
                (b for b in response.content if hasattr(b, "text")), None
            )
            if text_block is None:
                raise ValueError(f"No text block in response for claim {claim_id}")
            raw = text_block.text.strip()
            # Strip markdown code fences
            if raw.startswith("```"):
                raw = raw.split("```")[1]
                if raw.startswith("json"):
                    raw = raw[4:]
                raw = raw.strip()
            # If the model added prose, extract the first JSON object
            if not raw.startswith("{"):
                match = re.search(r"\{[^{}]*\}", raw, re.DOTALL)
                if match:
                    raw = match.group(0)
            data = json.loads(raw)
            decision = TriageDecision.model_validate(data)
            latency_ms = int(time.time() * 1000 - start_ms)
            usage = {
                "input_tokens": total_input_tokens,
                "output_tokens": total_output_tokens,
                "latency_ms": latency_ms,
            }
            return decision, usage

        # Execute tool calls and feed results back
        tool_results = []
        for block in response.content:
            if block.type == "tool_use":
                result = TOOL_MAP[block.name](**block.input)
                content = json.dumps(result)
                tool_results.append(
                    {
                        "type": "tool_result",
                        "tool_use_id": block.id,
                        "content": content if content else "{}",
                    }
                )

        if tool_results:
            messages += [
                {"role": "assistant", "content": response.content},
                {"role": "user", "content": tool_results},
            ]


# ---------------------------------------------------------------------------
# Confidence gate (Challenge 6, Step 3)
# ---------------------------------------------------------------------------


def apply_confidence_gate(decision: TriageDecision) -> TriageDecision:
    """Force low-confidence decisions to review regardless of model output."""
    if decision.confidence < 0.75 and decision.decision != "review":
        return TriageDecision(
            decision="review",
            confidence=decision.confidence,
            reason=f"[confidence gate] original={decision.decision} — {decision.reason}",
        )
    return decision


# ---------------------------------------------------------------------------
# Database write
# ---------------------------------------------------------------------------


def write_decision(claim_id: int, decision: TriageDecision, usage: dict) -> None:
    """Write triage result to the claim_triage table."""
    conn = _connect()
    try:
        cur = conn.cursor()
        cur.execute(
            "INSERT INTO claim_triage "
            "(claim_id, decision, confidence, reason, model, input_tokens, output_tokens, latency_ms) "
            "VALUES (%s, %s, %s, %s, %s, %s, %s, %s)",
            (
                claim_id,
                decision.decision,
                decision.confidence,
                decision.reason,
                MODEL,
                usage["input_tokens"],
                usage["output_tokens"],
                usage["latency_ms"],
            ),
        )
        conn.commit()
    finally:
        conn.close()


# ---------------------------------------------------------------------------
# Metrics push
# ---------------------------------------------------------------------------

# Cost per 1M tokens (Sonnet pricing)
INPUT_COST_PER_TOKEN = 3.0 / 1_000_000
OUTPUT_COST_PER_TOKEN = 15.0 / 1_000_000


def push_metrics(claim_id: int, decision: TriageDecision, usage: dict) -> None:
    """Push per-claim metrics to the Prometheus Pushgateway."""
    registry = CollectorRegistry()
    labels = {"decision": decision.decision, "claim_id": str(claim_id)}

    Gauge("llm_input_tokens_total", "Input tokens consumed", list(labels.keys()), registry=registry).labels(**labels).set(usage["input_tokens"])
    Gauge("llm_output_tokens_total", "Output tokens generated", list(labels.keys()), registry=registry).labels(**labels).set(usage["output_tokens"])
    Gauge("llm_latency_ms", "End-to-end agent latency in ms", list(labels.keys()), registry=registry).labels(**labels).set(usage["latency_ms"])
    cost = (
        usage["input_tokens"] * INPUT_COST_PER_TOKEN
        + usage["output_tokens"] * OUTPUT_COST_PER_TOKEN
    )
    Gauge("llm_cost_usd", "Estimated cost USD", list(labels.keys()), registry=registry).labels(**labels).set(cost)

    try:
        push_to_gateway(
            PUSHGATEWAY_URL,
            job="claims_triage",
            grouping_key={"claim_id": str(claim_id)},
            registry=registry,
        )
    except Exception as exc:
        print(f"  [warn] Pushgateway unavailable: {exc}")


# ---------------------------------------------------------------------------
# Batch runner
# ---------------------------------------------------------------------------


def fetch_pending_claims() -> list[int]:
    """Return IDs of all pending claims."""
    conn = _connect()
    try:
        cur = conn.cursor()
        cur.execute("SELECT claim_id FROM claims WHERE status = 'pending' ORDER BY claim_id")
        return [row[0] for row in cur.fetchall()]
    finally:
        conn.close()


def run_batch(claim_ids: list[int] | None = None) -> None:
    """Triage a list of claim IDs (or all pending claims)."""
    if claim_ids is None:
        claim_ids = fetch_pending_claims()

    print(f"Found {len(claim_ids)} pending claims.")

    for claim_id in claim_ids:
        print(f"Triaging claim {claim_id}... ", end="", flush=True)
        try:
            decision, usage = triage_claim(claim_id)
            decision = apply_confidence_gate(decision)
        except RuntimeError as exc:
            print(f"CIRCUIT BREAKER: {exc}")
            decision = TriageDecision(
                decision="review",
                confidence=0.0,
                reason="circuit breaker trip — routed to manual review",
            )
            usage = {"input_tokens": 0, "output_tokens": 0, "latency_ms": 0}

        write_decision(claim_id, decision, usage)
        push_metrics(claim_id, decision, usage)

        print(
            f"→ {decision.decision} (confidence={decision.confidence:.2f}) "
            f"| {usage['input_tokens']}+{usage['output_tokens']} tokens "
            f"| {usage['latency_ms']}ms"
        )


if __name__ == "__main__":
    run_batch()
