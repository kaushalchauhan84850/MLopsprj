"""Collector: every COLLECT_INTERVAL seconds build feature windows from
Prometheus, push each window to the Redis queue (consumed by the analyzer,
scaled by KEDA), keep a per-entity history ring for lag features, and append
to parquet history on the shared volume (training data for the trainer)."""
import json
import os
import time
from datetime import datetime

import pandas as pd
from prometheus_client import Gauge, start_http_server

from src.common import settings as S
from src.common.features import build_frames, frame_rows
from src.common.redis_client import get_redis

G_PENDING = Gauge("monitor_windows_pending", "Feature windows waiting in the analysis queue")


def flush_to_parquet(buffer):
    if not buffer:
        return
    os.makedirs(S.HISTORY_DIR, exist_ok=True)
    path = os.path.join(S.HISTORY_DIR, f"windows-{datetime.utcnow().strftime('%Y%m%d')}.parquet")
    df = pd.DataFrame(buffer)
    try:
        if os.path.exists(path):
            df = pd.concat([pd.read_parquet(path), df], ignore_index=True)
        df.to_parquet(path, index=False)
        print(f"[collector] flushed {len(buffer)} windows to {path}")
    except Exception as e:
        print(f"[collector] parquet flush failed (data stays in Redis queue): {e}")


def main():
    start_http_server(8080)
    r = get_redis()
    buffer, since_flush = [], 0
    print(f"[collector] starting: prom={S.PROM_URL} redis={S.REDIS_URL} interval={S.COLLECT_INTERVAL}s")
    while True:
        t0 = time.time()
        try:
            rows = []
            for etype, df in build_frames(S.PROM_URL).items():
                rows.extend(frame_rows(etype, df))
            for row in rows:
                payload = json.dumps(row)
                try:
                    r.lpush(S.QUEUE_KEY, payload)
                    r.ltrim(S.QUEUE_KEY, 0, 4999)
                    hk = f"{S.HIST_PREFIX}{row['_key']}"
                    r.lpush(hk, payload)
                    r.ltrim(hk, 0, 63)
                except Exception as e:
                    print(f"[collector] redis write failed: {e}")
                    break
            buffer.extend(rows)
            G_PENDING.set(r.llen(S.QUEUE_KEY))
            print(f"[collector] queued {len(rows)} windows (queue depth {r.llen(S.QUEUE_KEY)})")
        except Exception as e:
            print(f"[collector] cycle failed: {e}")

        since_flush += 1
        if since_flush >= S.FLUSH_EVERY:
            flush_to_parquet(buffer)
            buffer, since_flush = [], 0
        time.sleep(max(5, S.COLLECT_INTERVAL - (time.time() - t0)))


if __name__ == "__main__":
    main()
