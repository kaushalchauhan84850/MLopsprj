"""Demo app: intentionally breakable HTTP service with Prometheus metrics,
used to generate realistic telemetry (RPS, latency, 5xx) and incidents
(OOM via /burn, error storms via ERROR_RATE)."""
import os
import random
import threading
import time

from fastapi import FastAPI, HTTPException, Query
from fastapi.responses import PlainTextResponse
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Histogram, generate_latest

STATE = {"error_rate": float(os.getenv("ERROR_RATE", "0.03")),
         "base_latency_ms": float(os.getenv("BASE_LATENCY_MS", "40")),
         "not_ready": False}
_BURN = {}
_burn_lock = threading.Lock()

REQ = Counter("http_requests_total", "Total HTTP requests",
              ["method", "path", "status", "service"])
LAT = Histogram("http_request_duration_seconds", "Request latency", ["service"],
                buckets=(0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5))

app = FastAPI()


@app.middleware("http")
async def record_metrics(request, call_next):
    start = time.perf_counter()
    status = 500
    try:
        response = await call_next(request)
        status = response.status_code
        return response
    except HTTPException as e:
        status = e.status_code
        raise
    finally:
        LAT.labels("demo-app").observe(time.perf_counter() - start)
        REQ.labels(request.method, request.url.path, str(status), "demo-app").inc()


@app.get("/")
def index():
    time.sleep(random.uniform(0.5, 1.5) * STATE["base_latency_ms"] / 1000)
    return {"ok": True, "error_rate": STATE["error_rate"]}


@app.get("/slow")
def slow():
    time.sleep(random.uniform(2, 6) * STATE["base_latency_ms"] / 1000)
    return {"ok": True, "slow": True}


@app.get("/error")
def error():
    if random.random() < STATE["error_rate"]:
        raise HTTPException(status_code=500, detail="synthetic failure")
    return {"ok": True}


@app.get("/burn")
def burn(mb: int = Query(200), seconds: int = Query(60)):
    """Allocate mb MiB for `seconds` — set above the container limit to demo OOMKill."""
    def hold():
        with _burn_lock:
            _BURN[threading.get_ident()] = bytearray(mb * 1024 * 1024)
        time.sleep(seconds)
        with _burn_lock:
            _BURN.pop(threading.get_ident(), None)
    threading.Thread(target=hold, daemon=True).start()
    return {"burning": f"{mb}MiB for {seconds}s"}


@app.get("/config")
def config(error_rate: float = None, base_latency_ms: float = None,
           not_ready: bool = None):
    if error_rate is not None:
        STATE["error_rate"] = max(0.0, min(1.0, error_rate))
    if base_latency_ms is not None:
        STATE["base_latency_ms"] = max(0.0, base_latency_ms)
    if not_ready is not None:
        STATE["not_ready"] = not_ready
    return STATE


@app.get("/healthz")
def healthz():
    return {"ok": True}


@app.get("/readyz")
def readyz():
    if STATE["not_ready"]:
        raise HTTPException(status_code=503, detail="not ready (simulated)")
    return {"ok": True}


@app.get("/metrics")
def metrics():
    return PlainTextResponse(generate_latest(), media_type=CONTENT_TYPE_LATEST)
