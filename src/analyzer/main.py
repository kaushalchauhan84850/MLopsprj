"""AI Analyzer: the scoring + alerting service.

- Workers consume feature windows from the Redis queue (KEDA scales this
  deployment by queue depth via the monitor_windows_pending metric).
- Each window is scored by the ML model (anomaly score + failure probability),
  hot-reloading new model versions produced by the trainer.
- Anomalies / predicted failures / hard signals are pushed to Alertmanager's
  API, so predictive alerts flow through the same routing as normal alerts.
- Alertmanager routes ALL alerts (prometheus rules + AI) back to
  /webhook/alerts here, where they are enriched with Loki logs + k8s events
  into an RCA report (stored, and forwarded to Slack if configured).
"""
import json
import os
import threading
import time
from datetime import datetime, timedelta, timezone

import joblib
import requests
from fastapi import FastAPI, Request
from prometheus_client import Counter, Gauge, make_asgi_app

from src.analyzer import enrich
from src.analyzer.suggestions import get_suggestions
from src.common import settings as S
from src.common.features import compute_lags
from src.common.redis_client import get_redis

app = FastAPI(title="AI Analyzer", version="1.0")
app.mount("/metrics", make_asgi_app())

G_ANOMALY = Gauge("monitor_anomaly_score", "ML anomaly score per entity (0-1)", ["entity"])
G_RISK = Gauge("monitor_failure_risk", "Predicted probability of failure within horizon", ["entity"])
G_MODEL_AGE = Gauge("monitor_model_age_seconds", "Age of the loaded model")
G_MODEL_ROWS = Gauge("monitor_model_train_rows", "Rows used at model training time")
C_PROCESSED = Counter("monitor_windows_processed_total", "Feature windows scored")
C_ALERTS = Counter("monitor_alerts_sent_total", "Alerts pushed to Alertmanager", ["alertname"])

STATE = {"model": None, "version": "", "checked": 0.0}
_lock = threading.Lock()


def maybe_reload(force=False):
    now = time.time()
    if not force and now - STATE["checked"] < 30:
        return
    STATE["checked"] = now
    try:
        with open(os.path.join(S.MODEL_DIR, "model.meta.json")) as f:
            meta = json.load(f)
        if meta.get("version") != STATE["version"]:
            obj = joblib.load(os.path.join(S.MODEL_DIR, "model.joblib"))
            with _lock:
                STATE.update(model=obj, version=meta["version"])
            G_MODEL_ROWS.set(obj.get("rows", 0))
            print(f"[analyzer] loaded model {meta['version']} (rows={obj.get('rows')})")
    except FileNotFoundError:
        pass
    except Exception as e:
        print(f"[analyzer] model reload failed: {e}")


def _num(row, key, default=0.0):
    v = row.get(key)
    return float(v) if isinstance(v, (int, float)) and v == v else default


def hard_signal(etype, row):
    """Deterministic red flags that alert regardless of model state."""
    if etype == "pod":
        return _num(row, "restarts_15m") > 0 or _num(row, "oom_recent") > 0 or _num(row, "not_ready") > 0
    if etype == "pvc":
        return _num(row, "pvc_used_ratio") > 0.92
    if etype == "node":
        return _num(row, "pressure_signals") > 0
    if etype == "svc":
        return _num(row, "http_5xx_rate") > 1.0
    return False


def score(row, r):
    etype = row["_type"]
    res = {"anomaly_score": 0.0, "failure_prob": 0.0, "is_anomaly": False,
           "top_factors": [], "model_version": STATE["version"]}
    maybe_reload()
    m = STATE["model"]

    if m and etype in (m.get("entities") or {}):
        e = m["entities"][etype]
        cols = e["cols"]
        x = [float(row.get(c)) if isinstance(row.get(c), (int, float)) and row[c] == row[c]
             else float(e["med"][i]) for i, c in enumerate(cols)]
        s = -e["pipe"].decision_function([x])[0]
        a01 = (s - e["smin"]) / max(e["smax"] - e["smin"], 1e-9)
        res["anomaly_score"] = round(min(max(a01, 0.0), 1.0), 4)
        res["is_anomaly"] = bool(s >= e["thresh"])
        devs = sorted(((abs(x[i] - e["med"][i]) / (e["iqr"][i] + 1e-9), c)
                       for i, c in enumerate(cols)), reverse=True)
        res["top_factors"] = [f"{c}={x[cols.index(c)]:.3g} ({d:.1f}x IQR from baseline)"
                              for d, c in devs[:3] if d > 1.0]

    clf = (m or {}).get("clf")
    if clf and clf.get("model") and etype == "pod":
        try:
            prev = [json.loads(v) for v in r.lrange(f"{S.HIST_PREFIX}{row['_key']}", 1, S.LAG_WINDOW)]
        except Exception:
            prev = []
        lags = compute_lags(prev)
        cols = clf["cols"]
        xc = []
        for i, c in enumerate(cols):
            v = row.get(c)
            if not (isinstance(v, (int, float)) and v == v):
                v = lags.get(c)
            xc.append(float(v) if isinstance(v, (int, float)) and v == v else float(clf["med"][i]))
        res["failure_prob"] = round(float(clf["model"].predict_proba([xc])[0][1]), 4)
    return res


def p_threshold():
    clf = (STATE["model"] or {}).get("clf") or {}
    return clf.get("p_thresh", S.DEFAULT_P_THRESH)


def send_alert(row, res, etype, hard, suggestions):
    ns = row.get("namespace") or "-"
    name = row.get("name") or "-"
    if res["failure_prob"] >= p_threshold():
        alertname = "AIPredictedFailure"
    elif hard:
        alertname = "AIHardSignal"
    else:
        alertname = "AIAnomalyDetected"
    severity = "critical" if (res["failure_prob"] >= p_threshold() or hard) else "warning"

    labels = {"alertname": alertname, "ai_monitor": "1", "entity": row["_key"],
              "namespace": ns, "severity": severity, "entity_type": etype,
              etype: name}
    annotations = {
        "summary": f"{alertname} on {row['_key']}",
        "description": (f"anomaly_score={res['anomaly_score']:.3f} "
                        f"failure_prob={res['failure_prob']:.3f} "
                        f"model={res['model_version'] or 'rule-only'}; "
                        f"factors: {'; '.join(res['top_factors']) or 'n/a'}"),
        "debugging": "\n".join(f"• {s}" for s in suggestions),
    }
    now = datetime.now(timezone.utc)
    alert = {"labels": labels, "annotations": annotations,
             "startsAt": now.isoformat(), "endsAt": (now + timedelta(minutes=S.ALERT_TTL_MIN)).isoformat(),
             "generatorURL": "/"}
    try:
        resp = requests.post(f"{S.ALERTMANAGER_URL.rstrip('/')}/api/v2/alerts",
                             json=[alert], timeout=10)
        resp.raise_for_status()
        C_ALERTS.labels(alertname).inc()
        print(f"[analyzer] ALERT {alertname} severity={severity} -> {row['_key']}")
        return True
    except Exception as e:
        print(f"[analyzer] alertmanager push failed: {e}")
        return False


def worker(r):
    print(f"[analyzer] worker thread started")
    while True:
        try:
            item = r.blpop(S.QUEUE_KEY, timeout=5)
        except Exception as e:
            print(f"[analyzer] redis error: {e}")
            time.sleep(2)
            continue
        maybe_reload()
        if not item:
            continue
        try:
            row = json.loads(item[1])
            etype, key = row["_type"], row["_key"]
            res = score(row, r)
            suggestions = get_suggestions(etype, row, res)
            hard = hard_signal(etype, row)

            G_ANOMALY.labels(key).set(res["anomaly_score"])
            G_RISK.labels(key).set(res["failure_prob"])
            C_PROCESSED.inc()
            if STATE["model"]:
                G_MODEL_AGE.set(time.time() - STATE["model"]["created"])

            out = {"ts": datetime.now(timezone.utc).isoformat(), "entity": key,
                   **res, "hard_signal": hard, "suggestions": suggestions}
            try:
                r.rpush("results:recent", json.dumps(out))
                r.ltrim("results:recent", -500, -1)
            except Exception:
                pass

            should_alert = res["is_anomaly"] or res["failure_prob"] >= p_threshold() or hard
            if should_alert:
                dedup_key = f"alerted:{key}"
                if not r.exists(dedup_key):
                    if send_alert(row, res, etype, hard, suggestions):
                        r.setex(dedup_key, S.ALERT_DEDUP_MIN * 60, "1")
        except Exception as e:
            print(f"[analyzer] window scoring failed: {e}")


@app.on_event("startup")
def startup():
    maybe_reload(force=True)
    r = get_redis()
    for _ in range(max(1, S.WORKER_THREADS)):
        threading.Thread(target=worker, args=(r,), daemon=True).start()


@app.get("/healthz")
def healthz():
    return {"ok": True, "model_version": STATE["version"]}


@app.get("/results")
def results(limit: int = 50):
    r = get_redis()
    items = [json.loads(v) for v in r.lrange("results:recent", -limit, -1)]
    return items


@app.get("/rca")
def rca(limit: int = 50):
    r = get_redis()
    items = [json.loads(v) for v in r.lrange("rca:recent", -limit, -1)]
    return items


@app.post("/webhook/alerts")
async def webhook_alerts(request: Request):
    """Alertmanager sink: enrich every alert into an RCA report."""
    payload = await request.json()
    r = get_redis()
    processed = 0
    for a in payload.get("alerts", []):
        try:
            rca = enrich.build_rca(a)
            r.rpush("rca:recent", json.dumps(rca))
            r.ltrim("rca:recent", -200, -1)
            if S.SLACK_WEBHOOK_URL:
                enrich.send_to_slack(enrich.rca_to_slack_text(rca))
            print(f"[rca] {rca['alertname']} {rca['status']} on {rca['entity']} "
                  f"({len(rca['logs'])} log lines, {len(rca['events'])} events)")
            processed += 1
        except Exception as e:
            print(f"[rca] enrichment failed: {e}")
    return {"processed": processed}


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8080, log_level="info")
