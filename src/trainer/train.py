"""Trainer: the MLOps retraining loop.

Reads parquet feature history from the shared volume, then trains:
  1. Per entity type (pod/svc/node/pvc): StandardScaler + IsolationForest
     anomaly scorer, with a calibrated threshold (ANOMALY_QUANTILE of train
     scores) and median/IQR stats used to explain *why* something is anomalous.
  2. A HistGradientBoostingClassifier predicting "pod hits a failure
     (restart / OOM / not-ready) within PREDICTION_HORIZON_MIN" — labels are
     generated automatically from the history itself (self-supervised).

On a cold cluster (little/no history) it bootstraps from synthetic data so
the analyzer has a usable model from day one; it retrains on real data as
soon as enough accumulates. Artifacts are written atomically and versioned;
the analyzer hot-reloads on version change."""
import glob
import json
import os
import time

import joblib
import numpy as np
import pandas as pd
from sklearn.ensemble import HistGradientBoostingClassifier, IsolationForest
from sklearn.pipeline import Pipeline
from sklearn.preprocessing import StandardScaler

from src.common import settings as S
from src.common.features import ALL_COLS, CLF_COLS, compute_lags

SYNTHETIC_RANGES = {
    "cpu_ratio": (0.05, 0.75), "mem_ratio": (0.10, 0.85),
    "restarts_15m": (0, 0), "oom_recent": (0, 0), "not_ready": (0, 0),
    "net_err_10m": (0, 0), "net_drop_10m": (0, 0),
    "rps": (1, 80), "http_5xx_rate": (0, 0.2), "latency_p95": (0.02, 0.5),
    "node_cpu_used": (0.10, 0.70), "node_mem_used": (0.15, 0.80),
    "pressure_signals": (0, 0), "pvc_used_ratio": (0.10, 0.70),
}
ZERO_COLS = {"restarts_15m", "oom_recent", "not_ready", "net_err_10m",
             "net_drop_10m", "pressure_signals"}


def load_history():
    dfs = []
    for f in sorted(glob.glob(os.path.join(S.HISTORY_DIR, "*.parquet"))):
        try:
            dfs.append(pd.read_parquet(f))
        except Exception as e:
            print(f"[trainer] skipping unreadable {f}: {e}")
    if not dfs:
        return pd.DataFrame()
    df = pd.concat(dfs, ignore_index=True)
    return df.drop_duplicates(subset=["_key", "ts"])


def synthetic(etype, n=600):
    rng = np.random.default_rng(7)
    cols = ALL_COLS[etype]
    data = {c: rng.uniform(*SYNTHETIC_RANGES.get(c, (0, 1)), n) for c in cols}
    for c in ZERO_COLS & set(cols):
        data[c][:] = 0.0
    df = pd.DataFrame(data)
    df["_type"] = etype
    df["_key"] = f"synthetic/{etype}"
    df["ts"] = np.arange(n) * S.COLLECT_INTERVAL
    return df


def train_anomaly(entities, df, used_synthetic):
    for etype, cols in ALL_COLS.items():
        sub = df[df["_type"] == etype] if (not df.empty and "_type" in df.columns) else pd.DataFrame()
        real = len(sub)
        if real < 80 and not used_synthetic.get(etype):
            sub = pd.concat([sub, synthetic(etype)])
            used_synthetic[etype] = True
        X = sub[cols].apply(pd.to_numeric, errors="coerce").dropna().values
        if len(X) < 30:
            print(f"[trainer] not enough data for {etype} ({len(X)} rows), skipped")
            continue
        pipe = Pipeline([
            ("scaler", StandardScaler()),
            ("iforest", IsolationForest(n_estimators=150, contamination=0.02, random_state=7)),
        ]).fit(X)
        scores = -pipe.decision_function(X)  # higher = more anomalous
        thresh = float(np.quantile(scores, S.ANOMALY_QUANTILE))
        med = np.median(X, axis=0)
        iqr = np.subtract(*np.percentile(X, [75, 25], axis=0))
        entities[etype] = {
            "cols": cols, "pipe": pipe,
            "smin": float(scores.min()), "smax": float(scores.max()),
            "thresh": thresh, "med": med.tolist(), "iqr": iqr.tolist(),
        }
        print(f"[trainer] {etype}: iforest on {len(X)} rows (real={real}), thresh={thresh:.4f}")


def build_supervised(df):
    """Auto-label pods: label=1 if a failure signal occurs strictly within the
    next PREDICTION_HORIZON_MIN minutes for the same pod."""
    pods = df[(df["_type"] == "pod") & (~df["_key"].astype(str).str.startswith("synthetic"))]
    if pods.empty:
        return pd.DataFrame()
    recs = []
    horizon_s = S.PREDICTION_HORIZON_MIN * 60
    for key, g in pods.groupby("_key"):
        g = g.sort_values("ts")
        rows = g.to_dict("records")
        prev = []
        group_recs = []
        for row in rows:
            lags = compute_lags(prev)
            rec = {c: row.get(c) for c in ALL_COLS["pod"]}
            rec.update(lags)
            rec.update({"_key": key, "ts": row["ts"]})
            group_recs.append(rec)
            prev.insert(0, row)
            prev = prev[: S.LAG_WINDOW]
        for i, rec in enumerate(group_recs):
            label = 0
            for fut in group_recs[i + 1:]:
                if fut["ts"] - rec["ts"] > horizon_s:
                    break
                if (fut.get("restarts_15m") or 0) > 0 or (fut.get("oom_recent") or 0) > 0 \
                        or (fut.get("not_ready") or 0) > 0:
                    label = 1
                    break
            rec["label"] = label
        recs.extend(group_recs)
    return pd.DataFrame(recs)


def train_classifier(sup):
    if sup.empty:
        return None, 0
    clean = sup.dropna(subset=[c for c in ALL_COLS["pod"]])
    X = clean[CLF_COLS].apply(pd.to_numeric, errors="coerce")
    mask = X.notna().all(axis=1)
    X, y = X[mask].values, clean.loc[mask, "label"].values
    if len(X) < S.MIN_TRAIN_ROWS or y.sum() < S.MIN_POSITIVES:
        print(f"[trainer] clf skipped: {len(X)} rows / {int(y.sum())} positives "
              f"(need {S.MIN_TRAIN_ROWS}/{S.MIN_POSITIVES}); anomaly model + hard rules stay active")
        return None, int(y.sum())
    clf = HistGradientBoostingClassifier(max_iter=200, random_state=7).fit(X, y)
    proba = clf.predict_proba(X)[:, 1]
    best_t, best_f1 = 0.5, -1.0
    for t in np.arange(0.05, 0.96, 0.05):
        preds = proba >= t
        tp = ((preds == 1) & (y == 1)).sum()
        prec = tp / max(preds.sum(), 1)
        rec_ = tp / max(y.sum(), 1)
        f1 = 2 * prec * rec_ / max(prec + rec_, 1e-9)
        if f1 > best_f1:
            best_f1, best_t = f1, float(t)
    obj = {"cols": CLF_COLS, "model": clf, "p_thresh": best_t,
           "med": np.nanmedian(X, axis=0).tolist()}
    print(f"[trainer] clf trained on {len(X)} rows / {int(y.sum())} positives, "
          f"p_thresh={best_t:.2f} (train F1={best_f1:.2f})")
    return obj, int(y.sum())


def main():
    df = load_history()
    real_rows = len(df)
    entities, used_synthetic = {}, {}
    train_anomaly(entities, df if not df.empty else pd.DataFrame(), used_synthetic)
    if df.empty:
        df = pd.concat([synthetic(e) for e in ALL_COLS], ignore_index=True)

    sup = build_supervised(df)
    clf_obj, positives = train_classifier(sup)

    model = {
        "version": time.strftime("%Y%m%dT%H%M%S"),
        "created": time.time(),
        "rows": int(max(real_rows, len(df))),
        "real_rows": int(real_rows),
        "positives": positives,
        "entities": entities,
        "clf": clf_obj,
    }

    os.makedirs(S.MODEL_DIR, exist_ok=True)
    tmp = os.path.join(S.MODEL_DIR, "model.joblib.tmp")
    joblib.dump(model, tmp)
    os.replace(tmp, os.path.join(S.MODEL_DIR, "model.joblib"))
    meta_tmp = os.path.join(S.MODEL_DIR, "model.meta.json.tmp")
    with open(meta_tmp, "w") as f:
        json.dump({"version": model["version"], "created": model["created"],
                   "rows": model["rows"], "real_rows": model["real_rows"],
                   "positives": positives,
                   "etypes": sorted(entities.keys())}, f)
    os.replace(meta_tmp, os.path.join(S.MODEL_DIR, "model.meta.json"))
    print(f"[trainer] model {model['version']} saved "
          f"(history rows={real_rows}, entities={sorted(entities.keys())})")


if __name__ == "__main__":
    main()
