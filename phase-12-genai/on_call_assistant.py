"""
Phase 12 — On-Call Assistant
HTTP webhook server that receives Grafana alert payloads, investigates with tool use,
and posts a structured root cause hypothesis to a Slack webhook.
"""

import json
import os
import re
import sys
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

import anthropic

SLACK_WEBHOOK_URL = os.environ.get("SLACK_WEBHOOK_URL", "")
GRAFANA_URL = os.environ.get("GRAFANA_URL", "http://kube-prometheus-stack-grafana.monitoring.svc.cluster.local:80")
GRAFANA_TOKEN = os.environ.get("GRAFANA_TOKEN", "")
LOKI_URL = os.environ.get("LOKI_URL", "http://loki.monitoring.svc.cluster.local:3100")
PROMETHEUS_URL = os.environ.get("PROMETHEUS_URL", "http://kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090")

MODEL = "claude-sonnet-4-6"
MAX_TURNS = 8

SYSTEM_PROMPT = """You are an on-call SRE assistant for CoverLine's Kubernetes platform.

When a Grafana alert fires you will be given the alert name. Your job is to:
1. Get the alert details from Grafana (get_alert_details)
2. Query recent error logs from Loki (query_loki)
3. Query relevant metrics from Prometheus (query_prometheus)

After investigation, output ONLY a raw JSON object — no prose, no markdown, no explanation. Your entire response must be parseable by json.loads().

Schema:
{"summary": "...", "likely_cause": "...", "evidence": ["..."], "recommended_actions": ["..."], "severity": "low"|"medium"|"high"|"critical"}

Be specific. Cite actual metric values and log lines. Output ONLY the JSON object."""


# ---------------------------------------------------------------------------
# Tool implementations
# ---------------------------------------------------------------------------


def get_alert_details(alert_name: str) -> dict:
    """Query Grafana Alerting API for details on a named alert."""
    import urllib.request

    url = f"{GRAFANA_URL}/api/alertmanager/grafana/api/v2/alerts?filter=alertname%3D{alert_name}"
    headers = {"Accept": "application/json"}
    if GRAFANA_TOKEN:
        headers["Authorization"] = f"Bearer {GRAFANA_TOKEN}"

    try:
        req = urllib.request.Request(url, headers=headers)
        with urllib.request.urlopen(req, timeout=5) as resp:
            data = json.loads(resp.read())
        return {"alert_name": alert_name, "alerts": data[:5]}
    except Exception as exc:
        return {"alert_name": alert_name, "error": str(exc)}


def query_loki(query: str, limit: int = 20) -> dict:
    """Query Loki for recent log lines matching the given LogQL query."""
    import urllib.parse
    import urllib.request

    params = urllib.parse.urlencode({
        "query": query,
        "limit": limit,
        "start": str(int((time.time() - 600) * 1e9)),  # last 10 minutes
    })
    url = f"{LOKI_URL}/loki/api/v1/query_range?{params}"

    try:
        with urllib.request.urlopen(url, timeout=5) as resp:
            data = json.loads(resp.read())
        streams = data.get("data", {}).get("result", [])
        lines = []
        for stream in streams:
            for ts, line in stream.get("values", []):
                lines.append(line)
        return {"query": query, "lines": lines[:limit]}
    except Exception as exc:
        return {"query": query, "error": str(exc)}


def query_prometheus(promql: str) -> dict:
    """Query Prometheus for the current value of a PromQL expression."""
    import urllib.parse
    import urllib.request

    params = urllib.parse.urlencode({"query": promql})
    url = f"{PROMETHEUS_URL}/api/v1/query?{params}"

    try:
        with urllib.request.urlopen(url, timeout=5) as resp:
            data = json.loads(resp.read())
        return {"query": promql, "result": data.get("data", {}).get("result", [])}
    except Exception as exc:
        return {"query": promql, "error": str(exc)}


TOOL_MAP = {
    "get_alert_details": get_alert_details,
    "query_loki": query_loki,
    "query_prometheus": query_prometheus,
}

TOOLS = [
    {
        "name": "get_alert_details",
        "description": "Retrieve details of a Grafana alert by name from the Alertmanager API.",
        "input_schema": {
            "type": "object",
            "properties": {"alert_name": {"type": "string"}},
            "required": ["alert_name"],
        },
    },
    {
        "name": "query_loki",
        "description": "Query Loki for recent log lines using a LogQL expression.",
        "input_schema": {
            "type": "object",
            "properties": {
                "query": {"type": "string", "description": "LogQL query, e.g. '{namespace=\"default\"} |= \"ERROR\"'"},
                "limit": {"type": "integer", "default": 20},
            },
            "required": ["query"],
        },
    },
    {
        "name": "query_prometheus",
        "description": "Query Prometheus for the current value of a PromQL expression.",
        "input_schema": {
            "type": "object",
            "properties": {
                "promql": {"type": "string", "description": "PromQL expression, e.g. 'rate(http_requests_total{status=~\"5..\"}[5m])'"}
            },
            "required": ["promql"],
        },
    },
]


# ---------------------------------------------------------------------------
# Agentic investigation loop
# ---------------------------------------------------------------------------


def investigate(alert_name: str) -> dict:
    """Run the investigation agent and return a structured hypothesis."""
    client = anthropic.Anthropic()

    messages = [
        {"role": "user", "content": f"Alert fired: {alert_name}. Please investigate and provide a root cause hypothesis."}
    ]

    turn = 0
    while True:
        turn += 1

        # On the final turn call without tools to force end_turn + JSON output
        active_tools = [] if turn >= MAX_TURNS else TOOLS

        response = client.messages.create(
            model=MODEL,
            max_tokens=1024,
            system=SYSTEM_PROMPT,
            tools=active_tools if active_tools else anthropic.NOT_GIVEN,
            messages=messages,
        )

        if response.stop_reason == "end_turn":
            text_block = next((b for b in response.content if hasattr(b, "text")), None)
            if text_block:
                raw = text_block.text.strip()
                # Strip markdown fences
                if raw.startswith("```"):
                    raw = raw.split("```")[1]
                    if raw.startswith("json"):
                        raw = raw[4:]
                    raw = raw.strip()
                # Extract first JSON object (handles nested braces)
                if not raw.startswith("{"):
                    match = re.search(r"\{[\s\S]*\}", raw)
                    if match:
                        raw = match.group(0)
                try:
                    return json.loads(raw)
                except json.JSONDecodeError:
                    # Model returned prose — wrap it as a valid hypothesis
                    return {
                        "summary": raw[:200] if raw else "No structured response",
                        "likely_cause": "See summary — model returned unstructured output",
                        "evidence": [],
                        "recommended_actions": ["Review raw model output", "Investigate manually"],
                        "severity": "medium",
                    }
            return {"summary": "No text in response", "likely_cause": "unknown", "evidence": [], "recommended_actions": [], "severity": "medium"}

        tool_results = []
        for block in response.content:
            if block.type == "tool_use":
                result = TOOL_MAP[block.name](**block.input)
                content = json.dumps(result)
                tool_results.append({
                    "type": "tool_result",
                    "tool_use_id": block.id,
                    "content": content if content else "{}",
                })

        if tool_results:
            messages += [
                {"role": "assistant", "content": response.content},
                {"role": "user", "content": tool_results},
            ]


# ---------------------------------------------------------------------------
# Slack notification
# ---------------------------------------------------------------------------


def post_to_slack(hypothesis: dict) -> None:
    if not SLACK_WEBHOOK_URL:
        print("[on_call] No SLACK_WEBHOOK_URL — printing hypothesis:")
        print(json.dumps(hypothesis, indent=2))
        return

    import urllib.request

    severity_emoji = {"low": ":white_circle:", "medium": ":yellow_circle:", "high": ":orange_circle:", "critical": ":red_circle:"}
    emoji = severity_emoji.get(hypothesis.get("severity", "medium"), ":warning:")

    evidence_lines = "\n".join(f"  • `{e}`" for e in hypothesis.get("evidence", []))
    actions_lines = "\n".join(f"  • `{a}`" for a in hypothesis.get("recommended_actions", []))

    text = (
        f"{emoji} *On-call Alert Investigation*\n\n"
        f"*Summary:* {hypothesis.get('summary', '')}\n"
        f"*Likely cause:* {hypothesis.get('likely_cause', '')}\n\n"
        f"*Evidence:*\n{evidence_lines}\n\n"
        f"*Recommended actions:*\n{actions_lines}"
    )

    payload = json.dumps({"text": text}).encode()
    req = urllib.request.Request(
        SLACK_WEBHOOK_URL,
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req) as resp:
        print(f"[on_call] Slack response: {resp.status}")


# ---------------------------------------------------------------------------
# Webhook server
# ---------------------------------------------------------------------------


class GrafanaWebhookHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        content_length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(content_length)

        try:
            payload = json.loads(body)
        except json.JSONDecodeError:
            self.send_response(400)
            self.end_headers()
            return

        alert_name = payload.get("commonLabels", {}).get("alertname", "UnknownAlert")
        print(f"[on_call] Received alert: {alert_name}")

        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"OK")

        # Investigate asynchronously in a thread so the webhook returns immediately
        import threading
        def _handle():
            hypothesis = investigate(alert_name)
            post_to_slack(hypothesis)

        threading.Thread(target=_handle, daemon=True).start()

    def log_message(self, format, *args):
        print(f"[on_call] {self.address_string()} {format % args}")


def serve():
    server = HTTPServer(("0.0.0.0", 8888), GrafanaWebhookHandler)
    print("Listening for Grafana webhooks on :8888")
    server.serve_forever()


# ---------------------------------------------------------------------------
# CLI entrypoint
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    if len(sys.argv) > 1:
        # Direct invocation: python on_call_assistant.py <AlertName>
        alert = sys.argv[1]
        print(f"Investigating alert: {alert}")
        hypothesis = investigate(alert)
        print(json.dumps(hypothesis, indent=2))
        post_to_slack(hypothesis)
    else:
        serve()
