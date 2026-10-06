"""Constant background traffic for the demo app (weighted mix of normal /
slow / erroring requests)."""
import os
import random
import threading
import time

import requests

TARGET = os.getenv("TARGET", "http://demo-app.demo.svc:8080")
RPS = float(os.getenv("RPS", "25"))
THREADS = int(os.getenv("THREADS", "4"))

PATHS = [("/", 0.86), ("/slow", 0.08), ("/error", 0.06)]
_stats = {"ok": 0, "err": 0}


def pick_path():
    r, acc = random.random(), 0.0
    for p, w in PATHS:
        acc += w
        if r <= acc:
            return p
    return "/"


def worker(idx):
    pace = 1.0 / max(RPS / THREADS, 0.01)
    while True:
        start = time.time()
        try:
            requests.get(TARGET + pick_path(), timeout=5)
            _stats["ok"] += 1
        except Exception:
            _stats["err"] += 1
        time.sleep(max(0.0, pace - (time.time() - start)))


def main():
    print(f"[loadgen] target={TARGET} rps={RPS} threads={THREADS}")
    for i in range(max(1, THREADS)):
        threading.Thread(target=worker, args=(i,), daemon=True).start()
    while True:
        time.sleep(30)
        print(f"[loadgen] ok={_stats['ok']} err={_stats['err']}")


if __name__ == "__main__":
    main()
