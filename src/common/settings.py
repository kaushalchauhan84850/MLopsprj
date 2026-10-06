"""Central configuration. Every value can be overridden with an env var
(set them in k8s/ml/00-config.yaml ConfigMap or ai-ops-secrets Secret)."""
import os


def _env(key, default):
    return os.getenv(key, default)


def _int(key, default):
    try:
        return int(os.getenv(key, str(default)))
    except ValueError:
        return default


def _float(key, default):
    try:
        return float(os.getenv(key, str(default)))
    except ValueError:
        return default


# --- telemetry endpoints (in-cluster defaults) -----------------------------
PROM_URL = _env("PROM_URL", "http://kube-prometheus-stack-prometheus.monitoring.svc:9090")
LOKI_URL = _env("LOKI_URL", "http://loki.monitoring.svc:3100")
ALERTMANAGER_URL = _env("ALERTMANAGER_URL", "http://kube-prometheus-stack-alertmanager.monitoring.svc:9093")
REDIS_URL = _env("REDIS_URL", "redis://redis.ai-ops.svc:6379/0")

# --- collector --------------------------------------------------------------
COLLECT_INTERVAL = _int("COLLECT_INTERVAL", 60)          # seconds between windows
HISTORY_DIR = _env("HISTORY_DIR", "/data/history")
FLUSH_EVERY = _int("FLUSH_EVERY", 20)                    # cycles between parquet flushes

# --- feature / model --------------------------------------------------------
QUEUE_KEY = _env("QUEUE_KEY", "windows:pending")
HIST_PREFIX = _env("HIST_PREFIX", "hist:")
LAG_WINDOW = _int("LAG_WINDOW", 6)                       # prior samples for lag features
PREDICTION_HORIZON_MIN = _int("PREDICTION_HORIZON_MIN", 15)
MODEL_DIR = _env("MODEL_DIR", "/data/model")
ANOMALY_QUANTILE = _float("ANOMALY_QUANTILE", 0.98)
MIN_TRAIN_ROWS = _int("MIN_TRAIN_ROWS", 300)
MIN_POSITIVES = _int("MIN_POSITIVES", 25)

# --- analyzer ---------------------------------------------------------------
WORKER_THREADS = _int("WORKER_THREADS", 2)
ALERT_TTL_MIN = _int("ALERT_TTL_MIN", 30)                # predictive alert auto-resolve
ALERT_DEDUP_MIN = _int("ALERT_DEDUP_MIN", 15)            # min between alerts per entity
DEFAULT_P_THRESH = _float("DEFAULT_P_THRESH", 0.85)

# --- alerting / RCA ---------------------------------------------------------
SLACK_WEBHOOK_URL = _env("SLACK_WEBHOOK_URL", "")
