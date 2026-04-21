"""
Phase 12 — Weekly Summary Agent
Queries BigQuery for weekly claims stats and posts a summary to Slack via webhook.
"""

import json
import os

import anthropic

SLACK_WEBHOOK_URL = os.environ.get("SLACK_WEBHOOK_URL", "")
BIGQUERY_PROJECT = os.environ.get("BIGQUERY_PROJECT", "")
MODEL = "claude-sonnet-4-6"

SYSTEM_PROMPT = """You are a data analyst summarising weekly insurance claims performance for CoverLine's operations team.

You have access to a BigQuery tool that can run SQL queries against the claims data warehouse.

Use the tool to gather:
1. Total claims processed this week by decision type (approve/review/reject)
2. Average confidence score per decision type
3. Total LLM cost this week
4. Any claims that took unusually long (> 5000ms)

Then produce a concise Slack summary in this format:
- Start with a bold header: *Weekly Claims Triage Report — <week>*
- Show a table of decision counts and percentages
- Call out the total API cost vs. last week if available
- Flag any anomalies (high rejection rate, circuit breaker trips, latency spikes)
- End with a one-sentence operational health verdict

Keep the tone professional and brief — the audience is the ops team lead, not engineers."""


def query_bigquery(sql: str) -> dict:
    """Tool: run a SQL query against BigQuery and return the results."""
    try:
        from google.cloud import bigquery

        client = bigquery.Client(project=BIGQUERY_PROJECT)
        query_job = client.query(sql)
        rows = list(query_job.result())
        return {
            "rows": [dict(row) for row in rows],
            "row_count": len(rows),
        }
    except Exception as exc:
        return {"error": str(exc)}


TOOLS = [
    {
        "name": "query_bigquery",
        "description": "Run a SQL query against the CoverLine BigQuery data warehouse. "
        "The dataset is `coverline_dw`. Available tables: claims_fact, triage_fact, cost_daily.",
        "input_schema": {
            "type": "object",
            "properties": {
                "sql": {
                    "type": "string",
                    "description": "A valid BigQuery SQL query.",
                }
            },
            "required": ["sql"],
        },
    }
]

TOOL_MAP = {"query_bigquery": query_bigquery}


def post_to_slack(message: str) -> None:
    """Post a message to Slack via webhook."""
    if not SLACK_WEBHOOK_URL:
        print("[weekly_summary] No SLACK_WEBHOOK_URL set — printing to stdout:")
        print(message)
        return

    import urllib.request

    payload = json.dumps({"text": message}).encode()
    req = urllib.request.Request(
        SLACK_WEBHOOK_URL,
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req) as resp:
        status = resp.status
    print(f"[weekly_summary] Slack response: {status}")


def run_weekly_summary() -> str:
    """Run the weekly summary agent and return the generated message."""
    client = anthropic.Anthropic()

    messages = [
        {
            "role": "user",
            "content": "Generate the weekly claims triage summary for the past 7 days.",
        }
    ]

    while True:
        response = client.messages.create(
            model=MODEL,
            max_tokens=1024,
            system=SYSTEM_PROMPT,
            tools=TOOLS,
            messages=messages,
        )

        if response.stop_reason == "end_turn":
            text_block = next(
                (b for b in response.content if hasattr(b, "text")), None
            )
            return text_block.text if text_block else ""

        tool_results = []
        for block in response.content:
            if block.type == "tool_use":
                result = TOOL_MAP[block.name](**block.input)
                tool_results.append(
                    {
                        "type": "tool_result",
                        "tool_use_id": block.id,
                        "content": json.dumps(result, default=str),
                    }
                )

        messages += [
            {"role": "assistant", "content": response.content},
            {"role": "user", "content": tool_results},
        ]


if __name__ == "__main__":
    summary = run_weekly_summary()
    post_to_slack(summary)
