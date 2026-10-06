"""Alert enrichment: when Alertmanager forwards an alert to /webhook/alerts,
pull related error logs from Loki and Kubernetes events, and assemble an RCA
report (optionally forwarded to Slack)."""
import time
from datetime import datetime, timezone

import requests

from src.common import settings as S

LOKO_PATTERN = "(?i)error|exception|fatal|panic|traceback"


def loki_errors(namespace, pod, minutes=30, limit=15):
    """Last matching log lines for a pod from Loki."""
    if not (namespace and pod):
        return []
    q = '{namespace="%s", pod="%s"} |~ "%s"' % (namespace, pod, LOKO_PATTERN)
    params = {
        "query": q, "limit": limit, "direction": "backward",
        "start": str(int((time.time() - minutes * 60) * 1e9)),
        "end": str(int(time.time() * 1e9)),
    }
    try:
        r = requests.get(f"{S.LOKI_URL.rstrip('/')}/loki/api/v1/query_range",
                         params=params, timeout=10)
        body = r.json()
        lines = []
        for res in body.get("data", {}).get("result", []):
            for _, line in res.get("values", []):
                lines.append(line[:300])
        return lines[:limit]
    except Exception as e:
        return [f"(loki unavailable: {e})"]


def k8s_events(namespace, name):
    """Recent events for an object from the Kubernetes API."""
    if not (namespace and name):
        return []
    try:
        from kubernetes import client, config
        config.load_incluster_config()
        v1 = client.CoreV1Api()
        evs = v1.list_namespaced_event(
            namespace, field_selector=f"involvedObject.name={name}").items or []
        evs = sorted(evs, key=lambda e: (e.last_timestamp or e.event_time
                                         or datetime(1970, 1, 1, tzinfo=timezone.utc)), reverse=True)
        out = []
        for e in evs[:8]:
            ts = e.last_timestamp or e.event_time
            ts = ts.strftime("%H:%M:%S") if hasattr(ts, "strftime") else "-"
            out.append(f"{ts} {e.reason}: {e.message}")
        return out
    except Exception as e:
        return [f"(k8s events unavailable: {e})"]


def build_rca(alert):
    """Alertmanager alert payload -> RCA report dict."""
    labels = alert.get("labels", {}) or {}
    annotations = alert.get("annotations", {}) or {}
    ns = labels.get("namespace", "")
    pod = labels.get("pod") or (labels.get("entity", "").split("/")[-1]
                                if labels.get("entity", "").startswith("pod/") else "")
    name = labels.get("pod") or labels.get("service") or labels.get("node") or pod
    rca = {
        "ts": datetime.now(timezone.utc).isoformat(),
        "status": alert.get("status", "firing"),
        "alertname": labels.get("alertname", "unknown"),
        "severity": labels.get("severity", "info"),
        "namespace": ns or "-",
        "entity": labels.get("entity") or labels.get("pod") or name or "-",
        "summary": annotations.get("summary") or labels.get("alertname", ""),
        "description": annotations.get("description", ""),
        "logs": loki_errors(ns, pod),
        "events": k8s_events(ns, name),
        "suggestions": (annotations.get("debugging") or "").splitlines()
                       or ["Inspect the alert source metric in Grafana and recent rollouts"],
    }
    return rca


def rca_to_slack_text(rca):
    icon = ":rotating_light:" if rca["severity"] == "critical" else ":warning:"
    lines = [f"{icon} *[{rca['severity'].upper()}] {rca['alertname']}* — {rca['summary']}"]
    lines.append(f"Entity: `{rca['entity']}` (ns {rca['namespace']}) — status: {rca['status']}")
    if rca["description"]:
        lines.append(f"> {rca['description'][:400]}")
    if rca["events"]:
        lines.append("*Kubernetes events:*")
        lines += [f"• {e}" for e in rca["events"][:5]]
    if rca["logs"]:
        lines.append("*Recent error logs (Loki):*")
        lines += [f"• `{l}`" for l in rca["logs"][:5]]
    if rca["suggestions"]:
        lines.append("*Debugging steps:*")
        lines += [f"• {s.lstrip('• ')}" for s in rca["suggestions"][:6]]
    text = "\n".join(lines)
    return text[:3500]


def send_to_slack(text):
    if not S.SLACK_WEBHOOK_URL:
        return False
    try:
        requests.post(S.SLACK_WEBHOOK_URL, json={"text": text}, timeout=10)
        return True
    except Exception as e:
        print(f"[rca] slack send failed: {e}")
        return False
