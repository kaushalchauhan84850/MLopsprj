"""Feature engineering shared by collector, trainer and analyzer.

Builds per-entity feature windows from Prometheus:
  pod  : CPU/memory vs limits, restarts, OOM, readiness, network errors
  svc  : RPS, 5xx rate, p95 latency (any app exposing http_requests_total /
         http_request_duration_seconds_bucket, e.g. the bundled demo app)
  node : CPU/memory utilization, pressure conditions
  pvc  : volume fill ratio
"""
import time

import pandas as pd

from src.common.prom import instant_query

POD_COLS = ["cpu_ratio", "mem_ratio", "restarts_15m", "oom_recent",
            "not_ready", "net_err_10m", "net_drop_10m"]
SVC_COLS = ["rps", "http_5xx_rate", "latency_p95"]
NODE_COLS = ["node_cpu_used", "node_mem_used", "pressure_signals"]
PVC_COLS = ["pvc_used_ratio"]
ALL_COLS = {"pod": POD_COLS, "svc": SVC_COLS, "node": NODE_COLS, "pvc": PVC_COLS}

LAG_COLS = ["cpu_ratio_mean", "cpu_ratio_std", "mem_ratio_mean", "mem_ratio_std", "restarts_sum"]
CLF_COLS = POD_COLS + LAG_COLS  # supervised model uses pod features + lags

Q = {
    "cpu_usage": 'sum by (namespace, pod) (rate(container_cpu_usage_seconds_total{container!="",container!="POD"}[2m]))',
    "cpu_limit": 'max by (namespace, pod) (kube_pod_container_resource_limits{resource="cpu"})',
    "mem_usage": 'max by (namespace, pod) (container_memory_working_set_bytes{container!="",container!="POD"})',
    "mem_limit": 'max by (namespace, pod) (kube_pod_container_resource_limits{resource="memory"})',
    "restarts": 'sum by (namespace, pod) (increase(kube_pod_container_status_restarts_total[15m]))',
    "oom": 'max by (namespace, pod) (kube_pod_container_status_last_terminated_reason{reason="OOMKilled"})',
    "not_ready": 'max by (namespace, pod) (kube_pod_status_ready{condition="false"})',
    "net_err": 'sum by (namespace, pod) (increase(container_network_receive_errors_total[10m]))',
    "net_drop": 'sum by (namespace, pod) (increase(container_network_receive_packets_dropped_total[10m]))',
    "rps": 'sum by (namespace, service) (rate(http_requests_total[2m]))',
    "http_5xx": 'sum by (namespace, service) (rate(http_requests_total{status=~"5.."}[2m]))',
    "latency_p95": 'histogram_quantile(0.95, sum by (le, namespace, service) (rate(http_request_duration_seconds_bucket[2m])))',
    "node_cpu": '1 - avg by (node) (rate(node_cpu_seconds_total{mode="idle"}[2m]))',
    "node_mem": '1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)',
    "node_pressure": 'sum by (node) (kube_node_status_condition{condition=~"MemoryPressure|DiskPressure|PIDPressure", status="true"})',
    "pvc_used": '1 - (kubelet_volume_stats_available_bytes / kubelet_volume_stats_capacity_bytes)',
}

ENTITY_KEYS = {"pod": ["namespace", "pod"], "svc": ["namespace", "service"],
               "node": ["node"], "pvc": ["namespace", "persistentvolumeclaim"]}


def _frame(prom_url, name, keys, col):
    """Query -> DataFrame indexed by the entity key labels, one value column."""
    res = instant_query(prom_url, Q[name])
    idx, vals = [], []
    for m, v in res:
        parts = []
        for k in keys:
            val = m.get(k) or (m.get("instance") if k == "node" else None)
            if not val:
                parts = None
                break
            parts.append(val)
        if parts:
            idx.append(tuple(parts))
            vals.append(float(v))
    if not idx:
        return pd.DataFrame()
    df = pd.DataFrame({col: vals}, index=pd.MultiIndex.from_tuples(idx, names=keys))
    return df[~df.index.duplicated(keep="first")]


def build_frames(prom_url):
    """Return {entity_type: DataFrame} of current feature values."""
    frames = {}

    pod_frames = [
        _frame(prom_url, "cpu_usage", ["namespace", "pod"], "cpu_usage"),
        _frame(prom_url, "cpu_limit", ["namespace", "pod"], "cpu_limit"),
        _frame(prom_url, "mem_usage", ["namespace", "pod"], "mem_usage"),
        _frame(prom_url, "mem_limit", ["namespace", "pod"], "mem_limit"),
        _frame(prom_url, "restarts", ["namespace", "pod"], "restarts_15m"),
        _frame(prom_url, "oom", ["namespace", "pod"], "oom_recent"),
        _frame(prom_url, "not_ready", ["namespace", "pod"], "not_ready"),
        _frame(prom_url, "net_err", ["namespace", "pod"], "net_err_10m"),
        _frame(prom_url, "net_drop", ["namespace", "pod"], "net_drop_10m"),
    ]
    pod = _outer_join(pod_frames)
    if not pod.empty:
        # limits may be entirely absent on clusters that don't expose KSM limit
        # metrics — fall back to raw usage so windows still flow
        if "cpu_limit" in pod:
            pod["cpu_ratio"] = pod["cpu_usage"] / pod["cpu_limit"].clip(lower=0.05)
        if "mem_limit" in pod:
            pod["mem_ratio"] = pod["mem_usage"] / pod["mem_limit"].clip(lower=1e6)
        frames["pod"] = pod

    svc = _outer_join([
        _frame(prom_url, "rps", ["namespace", "service"], "rps"),
        _frame(prom_url, "http_5xx", ["namespace", "service"], "http_5xx_rate"),
        _frame(prom_url, "latency_p95", ["namespace", "service"], "latency_p95"),
    ])
    if not svc.empty:
        frames["svc"] = svc

    node = _outer_join([
        _frame(prom_url, "node_cpu", ["node"], "node_cpu_used"),
        _frame(prom_url, "node_mem", ["node"], "node_mem_used"),
        _frame(prom_url, "node_pressure", ["node"], "pressure_signals"),
    ])
    if not node.empty:
        frames["node"] = node

    pvc = _frame(prom_url, "pvc_used", ["namespace", "persistentvolumeclaim"], "pvc_used_ratio")
    if not pvc.empty:
        frames["pvc"] = pvc

    return frames


def _outer_join(dfs):
    dfs = [d for d in dfs if not d.empty]
    if not dfs:
        return pd.DataFrame()
    out = dfs[0]
    for d in dfs[1:]:
        out = out.join(d, how="outer")
    return out[~out.index.duplicated(keep="first")]


def frame_rows(etype, df):
    """Yield JSON-safe row dicts (NaN -> None) from a feature DataFrame."""
    if df is None or df.empty:
        return
    keys = ENTITY_KEYS[etype]
    for idx, row in df.iterrows():
        has_ns = len(keys) > 1
        ns = idx[0] if has_ns else ""
        name = idx[-1]
        key = f"{etype}/{ns}/{name}" if has_ns else f"{etype}/{name}"
        out = {"_type": etype, "_key": key, "namespace": ns or None,
               "name": name, "ts": time.time()}
        for c in ALL_COLS[etype]:
            v = row.get(c)
            out[c] = float(v) if isinstance(v, (int, float)) and v == v else None
        yield out


def compute_lags(prev_rows):
    """Lag features from up to LAG_WINDOW previous samples of the same entity.
    prev_rows: list of row dicts, newest first (Redis lrange order)."""
    out = {}
    for c in ("cpu_ratio", "mem_ratio"):
        vals = [p[c] for p in prev_rows
                if isinstance(p.get(c), (int, float)) and p[c] == p[c]]
        if vals:
            mean = sum(vals) / len(vals)
            out[f"{c}_mean"] = mean
            out[f"{c}_std"] = (sum((v - mean) ** 2 for v in vals) / len(vals)) ** 0.5
        else:
            out[f"{c}_mean"] = None
            out[f"{c}_std"] = None
    out["restarts_sum"] = sum(
        (p.get("restarts_15m") or 0) for p in prev_rows[:3]
        if isinstance(p.get("restarts_15m") or 0, (int, float)))
    return out
