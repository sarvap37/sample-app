#!/usr/bin/env python3
"""
AIOps Triage Bot — Phases 5 & 6 of the local DevOps/AIOps learning pipeline.

Receives Alertmanager webhooks, gathers context from Prometheus + Loki,
calls Claude to produce an actionable triage report, and optionally
executes auto-remediation actions.

Usage:
  ANTHROPIC_API_KEY=sk-... python bot.py           # triage only
  ANTHROPIC_API_KEY=sk-... REMEDIATE=true python bot.py  # triage + auto-fix

Environment variables:
  ANTHROPIC_API_KEY  — Claude API key (required for AI analysis)
  REMEDIATE          — set to "true" to enable auto-remediation (default: false)
  PROMETHEUS_URL     — default: http://localhost:9090
  LOKI_URL           — default: http://localhost:3100  (needs port-forward)
  PORT               — webhook listener port (default: 5001)
"""

import json
import os
import threading
import time
from datetime import datetime, timedelta, timezone

import anthropic
import requests
from flask import Flask, jsonify, request

from remediate import remediate as auto_remediate

app = Flask(__name__)

PROMETHEUS_URL = os.getenv("PROMETHEUS_URL", "http://localhost:9090")
LOKI_URL = os.getenv("LOKI_URL", "http://localhost:3100")
ANTHROPIC_API_KEY = os.getenv("ANTHROPIC_API_KEY", "")
REMEDIATE_ENABLED = os.getenv("REMEDIATE", "false").lower() == "true"
POLL_INTERVAL = int(os.getenv("POLL_INTERVAL", "20"))  # seconds between Prometheus polls

# Tracks fingerprints of alerts we've already acted on this firing cycle.
# Cleared when an alert resolves so it can be re-processed if it re-fires.
_active_alerts: dict[str, str] = {}  # fingerprint → activeAt

# ---------------------------------------------------------------------------
# Context gathering
# ---------------------------------------------------------------------------

def query_prometheus_instant(promql: str) -> list:
    """Run an instant PromQL query."""
    try:
        resp = requests.get(
            f"{PROMETHEUS_URL}/api/v1/query",
            params={"query": promql},
            timeout=5,
        )
        resp.raise_for_status()
        return resp.json().get("data", {}).get("result", [])
    except Exception as exc:
        return [{"error": str(exc)}]


def query_prometheus_range(promql: str, minutes: int = 5) -> list:
    """Run a PromQL range query over the last N minutes."""
    now = datetime.now(timezone.utc)
    try:
        resp = requests.get(
            f"{PROMETHEUS_URL}/api/v1/query_range",
            params={
                "query": promql,
                "start": (now - timedelta(minutes=minutes)).isoformat(),
                "end": now.isoformat(),
                "step": "30s",
            },
            timeout=5,
        )
        resp.raise_for_status()
        return resp.json().get("data", {}).get("result", [])
    except Exception as exc:
        return [{"error": str(exc)}]


def query_loki(pod: str, limit: int = 40) -> str:
    """Fetch recent log lines from Loki for a specific pod."""
    now = datetime.now(timezone.utc)
    start = now - timedelta(minutes=15)
    try:
        resp = requests.get(
            f"{LOKI_URL}/loki/api/v1/query_range",
            params={
                "query": f'{{pod="{pod}"}}',
                "start": int(start.timestamp() * 1e9),
                "end": int(now.timestamp() * 1e9),
                "limit": limit,
                "direction": "BACKWARD",
            },
            timeout=5,
        )
        resp.raise_for_status()
        streams = resp.json().get("data", {}).get("result", [])
        lines = []
        for stream in streams:
            for _, line in stream.get("values", []):
                lines.append(line)
        if not lines:
            return "(no recent logs found)"
        return "\n".join(reversed(lines))
    except Exception as exc:
        return f"(Loki unavailable: {exc})"


def gather_metrics_context(pod: str, namespace: str) -> str:
    """Pull relevant Prometheus metrics for a given pod and return as text."""
    parts = []

    # Memory usage vs limit
    mem = query_prometheus_instant(
        f'container_memory_working_set_bytes{{pod="{pod}",container="hello-world-app"}}'
    )
    mem_limit = query_prometheus_instant(
        f'container_spec_memory_limit_bytes{{pod="{pod}",container="hello-world-app"}}'
    )
    if mem and "value" in mem[0]:
        used_mb = int(float(mem[0]["value"][1])) // (1024 * 1024)
        parts.append(f"Memory used: {used_mb}Mi")
    if mem_limit and "value" in mem_limit[0]:
        limit_mb = int(float(mem_limit[0]["value"][1])) // (1024 * 1024)
        parts.append(f"Memory limit: {limit_mb}Mi")

    # Restart count
    restarts = query_prometheus_instant(
        f'kube_pod_container_status_restarts_total{{pod="{pod}",container="hello-world-app"}}'
    )
    if restarts and "value" in restarts[0]:
        parts.append(f"Total restarts: {restarts[0]['value'][1]}")

    # Recent restart rate
    restart_rate = query_prometheus_instant(
        f'increase(kube_pod_container_status_restarts_total{{pod="{pod}"}}[1h])'
    )
    if restart_rate and "value" in restart_rate[0]:
        parts.append(f"Restarts in last 1h: {float(restart_rate[0]['value'][1]):.1f}")

    # HTTP request rate (last 5 min)
    req_rate = query_prometheus_instant(
        'rate(http_requests_total{job="hello-world-app"}[5m])'
    )
    if req_rate:
        total = sum(float(r["value"][1]) for r in req_rate if "value" in r)
        parts.append(f"HTTP request rate (5m): {total:.3f} req/s")

    # Waiting reason (CrashLoopBackOff etc.)
    waiting = query_prometheus_instant(
        f'kube_pod_container_status_waiting_reason{{pod="{pod}",container="hello-world-app"}}'
    )
    for w in waiting:
        if "value" in w and w["value"][1] == "1":
            reason = w.get("metric", {}).get("reason", "unknown")
            parts.append(f"Container waiting reason: {reason}")

    # Last terminated reason (OOMKilled etc.)
    terminated = query_prometheus_instant(
        f'kube_pod_container_status_last_terminated_reason{{pod="{pod}",container="hello-world-app"}}'
    )
    for t in terminated:
        if "value" in t and t["value"][1] == "1":
            reason = t.get("metric", {}).get("reason", "unknown")
            parts.append(f"Last termination reason: {reason}")

    return "\n".join(parts) if parts else "(no metrics available)"


# ---------------------------------------------------------------------------
# Claude triage
# ---------------------------------------------------------------------------

TRIAGE_SYSTEM = """You are an expert SRE on-call assistant. You receive Kubernetes alerts with supporting
metrics and pod logs. Your job is to provide a concise, actionable triage report so the engineer
on-call can resolve the issue as fast as possible."""

TRIAGE_PROMPT = """Analyze this Kubernetes alert and generate a triage report.

{alert_context}

Respond in exactly this format (keep each section to 1-3 sentences):

**Alert**: {alert_name}
**Severity**: {severity}

**Likely Cause**:
<what is probably wrong, based on the metrics and logs>

**Immediate Action**:
<specific kubectl commands or steps to take right now>

**Root Cause Investigation**:
<what to check next to understand the full picture>

**Recommended Fix**:
<code change or config change to prevent recurrence>

**Severity Assessment**: <P1/P2/P3> — <one-line reason>"""


def call_claude(alert_name: str, severity: str, alert_context: str) -> str:
    if not ANTHROPIC_API_KEY:
        return "(AI analysis disabled — set ANTHROPIC_API_KEY to enable)"

    client = anthropic.Anthropic(api_key=ANTHROPIC_API_KEY)
    prompt = TRIAGE_PROMPT.format(
        alert_name=alert_name,
        severity=severity,
        alert_context=alert_context,
    )
    try:
        msg = client.messages.create(
            model="claude-haiku-4-5-20251001",
            max_tokens=1024,
            system=TRIAGE_SYSTEM,
            messages=[{"role": "user", "content": prompt}],
        )
        return msg.content[0].text
    except Exception as exc:
        return f"(Claude API error: {exc})"


# ---------------------------------------------------------------------------
# Webhook handler
# ---------------------------------------------------------------------------

def process_alert(alert: dict) -> None:
    labels = alert.get("labels", {})
    annotations = alert.get("annotations", {})
    alert_name = labels.get("alertname", "unknown")
    status = alert.get("status", "unknown")
    severity = labels.get("severity", "unknown")
    pod = labels.get("pod", "")
    namespace = labels.get("namespace", "default")

    sep = "─" * 60
    print(f"\n{sep}")
    print(f"  [{status.upper()}] {alert_name}  severity={severity}")
    print(f"  pod={pod or '(none)'}  namespace={namespace}")
    print(f"  started={alert.get('startsAt', 'N/A')}")
    if annotations.get("summary"):
        print(f"  summary={annotations['summary']}")
    print(sep)

    # Gather context
    metrics_ctx = gather_metrics_context(pod, namespace) if pod else "(no pod label)"
    logs_ctx = query_loki(pod) if pod else "(no pod label)"

    alert_context = f"""ALERT DETAILS:
  Name:      {alert_name}
  Status:    {status}
  Severity:  {severity}
  Pod:       {pod or 'N/A'}
  Namespace: {namespace}
  Started:   {alert.get('startsAt', 'N/A')}
  Summary:   {annotations.get('summary', 'N/A')}
  Description: {annotations.get('description', 'N/A')}
  Runbook:   {annotations.get('runbook', 'N/A')}

PROMETHEUS METRICS (current):
{metrics_ctx}

RECENT POD LOGS (last 15 min):
{logs_ctx}"""

    print("\n  Querying Claude for triage analysis...\n")
    analysis = call_claude(alert_name, severity, alert_context)
    print("  " + "\n  ".join(analysis.splitlines()))

    if REMEDIATE_ENABLED and status == "firing":
        print("\n  ── Auto-remediation ──")
        action = auto_remediate(alert_name, pod, namespace)
        print(f"  {action}")

    print()


@app.route("/webhook", methods=["POST"])
def webhook():
    data = request.get_json(force=True, silent=True) or {}
    alerts = data.get("alerts", [])

    print(f"\n{'═' * 60}")
    print(f"  ALERTMANAGER WEBHOOK — {len(alerts)} alert(s) — {datetime.now().strftime('%H:%M:%S')}")
    print(f"{'═' * 60}")

    for alert in alerts:
        process_alert(alert)

    return jsonify({"status": "ok", "processed": len(alerts)}), 200


@app.route("/health", methods=["GET"])
def health():
    return jsonify({"status": "ok"}), 200


@app.route("/test", methods=["POST"])
def test_alert():
    """Inject a synthetic CrashLoopBackOff alert for local testing."""
    fake_pod = "hello-world-app-test-abc123"
    fake = {
        "receiver": "aioops-bot",
        "status": "firing",
        "alerts": [{
            "status": "firing",
            "labels": {
                "alertname": "HelloWorldPodCrashLooping",
                "severity": "critical",
                "namespace": "default",
                "pod": fake_pod,
                "container": "hello-world-app",
                "reason": "CrashLoopBackOff",
            },
            "annotations": {
                "summary": f"Pod {fake_pod} is in CrashLoopBackOff",
                "description": f"Container hello-world-app in pod {fake_pod} has been crash looping for 1 minute.",
                "runbook": f"kubectl logs {fake_pod} --previous -n default",
            },
            "startsAt": datetime.now(timezone.utc).isoformat(),
        }],
    }
    with app.test_client() as c:
        c.post("/webhook", json=fake)
    return jsonify({"status": "ok", "message": "test alert injected"}), 200


# ---------------------------------------------------------------------------
# Prometheus alert poller (primary trigger mechanism)
# ---------------------------------------------------------------------------

def _poll_prometheus_alerts() -> None:
    """
    Poll Prometheus /api/v1/alerts every POLL_INTERVAL seconds.
    When a new firing alert appears, run triage + optional remediation.
    Avoids the Alertmanager webhook networking problem entirely.
    """
    print(f"  [poll] Started — checking Prometheus every {POLL_INTERVAL}s")
    while True:
        time.sleep(POLL_INTERVAL)
        try:
            resp = requests.get(f"{PROMETHEUS_URL}/api/v1/alerts", timeout=5)
            if not resp.ok:
                continue

            firing_now: set[str] = set()

            for alert in resp.json().get("data", {}).get("alerts", []):
                if alert.get("state") != "firing":
                    continue

                labels = alert.get("labels", {})
                # Only handle our app's alerts
                if not labels.get("alertname", "").startswith("HelloWorld"):
                    continue

                fingerprint = json.dumps(labels, sort_keys=True)
                firing_now.add(fingerprint)

                if fingerprint not in _active_alerts:
                    _active_alerts[fingerprint] = alert.get("activeAt", "")
                    print(f"\n  [poll] New firing alert detected: {labels.get('alertname')}")
                    process_alert({
                        "status": "firing",
                        "labels": labels,
                        "annotations": alert.get("annotations", {}),
                        "startsAt": alert.get("activeAt", ""),
                    })

            # Forget alerts that are no longer firing so they can be re-processed if they re-fire
            for fp in list(_active_alerts.keys()):
                if fp not in firing_now:
                    del _active_alerts[fp]

        except Exception as exc:
            print(f"  [poll] Error querying Prometheus: {exc}")


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    port = int(os.getenv("PORT", "5001"))
    print("━━━ AIOps Triage Bot ━━━")
    print(f"  Webhook  → http://0.0.0.0:{port}/webhook  (manual/test)")
    print(f"  Polling  → {PROMETHEUS_URL}/api/v1/alerts  every {POLL_INTERVAL}s  (primary)")
    print(f"  Health   → http://0.0.0.0:{port}/health")
    print(f"  Test     → POST http://localhost:{port}/test")
    print(f"  Loki:       {LOKI_URL}")
    print(f"  Claude AI:  {'✓ configured' if ANTHROPIC_API_KEY else '✗ NOT SET — set ANTHROPIC_API_KEY'}")
    print(f"  Remediate:  {'✓ ENABLED' if REMEDIATE_ENABLED else '✗ disabled (set REMEDIATE=true to enable)'}")
    print()

    threading.Thread(target=_poll_prometheus_alerts, daemon=True).start()
    app.run(host="0.0.0.0", port=port, debug=False)
