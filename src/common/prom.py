"""Minimal Prometheus HTTP API client."""
import requests


def instant_query(prom_url: str, query: str, timeout: int = 20):
    """Run an instant PromQL query. Returns [(labels_dict, float_value), ...]."""
    url = f"{prom_url.rstrip('/')}/api/v1/query"
    resp = requests.get(url, params={"query": query}, timeout=timeout)
    resp.raise_for_status()
    body = resp.json()
    if body.get("status") != "success":
        raise RuntimeError(f"Prometheus error: {body.get('error')}")
    out = []
    for r in body.get("data", {}).get("result", []):
        try:
            out.append((r.get("metric", {}), float(r["value"][1])))
        except (KeyError, IndexError, ValueError, TypeError):
            continue
    return out
