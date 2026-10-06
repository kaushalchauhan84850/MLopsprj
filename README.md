# k8s-ai-ops — ML-powered Kubernetes & Application Health Monitoring

A complete, deployable MLOps monitoring stack for Kubernetes. It watches your
**cluster health** (nodes, pods, volumes) and **application health** (RPS,
latency, 5xx), learns what "normal" looks like, **predicts failures before
they happen**, raises alerts, and attaches **debugging suggestions + related
logs/events** to every alert. Scaling is event-driven via **KEDA**, telemetry
comes from **Prometheus / Grafana / Loki**.

## What you get

| Capability | How |
|---|---|
| Cluster + app metrics | kube-prometheus-stack (Prometheus, Alertmanager, Grafana, kube-state-metrics, node-exporter) |
| Log aggregation | Loki + Promtail (all container logs) |
| Known failure alerts | PrometheusRule file with debug annotations (crashloops, OOM, node pressure, 5xx, latency, PVC fill…) |
| **ML anomaly detection** | IsolationForest per entity type (pod / service / node / PVC), retrained on a schedule |
| **Failure prediction** | Gradient-boosted classifier: "will this pod fail (restart/OOM/not-ready) in the next 15 min?" — labels auto-generated from history |
| **Alerts with debugging points** | Alerts pushed to Alertmanager with step-by-step `kubectl` suggestions + top statistical deviations explaining *why* |
| **RCA reports** | Alertmanager webhook → analyzer pulls Loki error logs + Kubernetes events → report (Slack-forwardable) |
| **Event-driven autoscaling** | KEDA scales the analyzer by analysis-queue depth, and the demo app by real request rate |

## Architecture

```
                          ┌────────────────────────────────────────────────────────┐
                          │                     Kubernetes cluster                 │
                          │                                                        │
 ┌──────────────┐  scrape │ ┌────────────┐   ┌─────────┐   ┌────────────────────┐  │
 │  Prometheus  │◄────────┤ │node-export │   │ kube-   │   │  your apps +       │  │
 │  + Alertmgr  │         │ │kube-state- │   │ metrics │   │  demo-app (/metrics)│ │
 │  + Grafana   │         │ └────────────┘   └─────────┘   └────────────────────┘  │
 └──────┬───────┘         │        │ Promtail ships container logs                 │
        │                 │        ▼                                               │
        │ PromQL          │    ┌─────────┐                                          │
        ▼                 │    │  Loki   │                                          │
 ┌──────────────┐ metrics │    └────┬────┘                                          │
 │ ai-collector │         │         │ log query                                     │
 │ feature      │────────►│         │                                               │
 │ windows      │ Redis   │  ┌──────┴───────┐  model   ┌──────────────────┐          │
 └──────┬───────┘ queue   │  │  ai-analyzer │◄─────────│  ai-trainer      │          │
        │                │  │  (KEDA-      │ .joblib  │  CronJob every   │          │
        │ windows:pending │  │   scaled)    │  PVC     │  6h + bootstrap  │          │
        └────────────────►│  └──────┬───────┘          └────────▲─────────┘          │
                         │         │ ① anomaly score            │ parquet history    │
                         │         │ ② failure probability      │ (from collector)   │
                         │         ▼                            │                    │
                         │  POST alerts → Alertmanager API ────┘                    │
                         │         │                                                │
                         │         ▼ webhook (ALL alerts)                           │
                         │  ai-analyzer /webhook/alerts → Loki logs + k8s events    │
                         │         │  → RCA report → Slack (optional)               │
                         └────────────────────────────────────────────────────────┘
```

**Data flow:** collector builds per-entity feature windows from Prometheus
every 60s → pushes them to a Redis queue (and to parquet history on a PVC) →
analyzer workers (KEDA-scaled by queue depth) score each window with the
current model → anomalies / predicted failures / hard signals become alerts
via Alertmanager's API → Alertmanager routes every alert back to the
analyzer's webhook, which enriches it with Loki logs + Kubernetes events into
an RCA report with debugging steps. The trainer retrains models every 6h from
accumulated history; the analyzer hot-reloads new model versions.

## Repository layout

```
k8s-ai-ops/
├── dashboards/ai-ops-overview.json      # Grafana dashboard (auto-provisioned)
├── docker/Dockerfile, demo-app.Dockerfile
├── k8s/
│   ├── 00-namespaces.yaml               # monitoring / ai-ops / demo
│   ├── monitoring/
│   │   ├── kube-prometheus-stack-values.yaml  # + Alertmanager→RCA webhook, Loki datasource
│   │   ├── loki-values.yaml, promtail-values.yaml
│   │   └── prometheus-rules.yaml        # known failure modes w/ debug hints
│   ├── keda/scaledobjects.yaml          # analyzer (queue depth) + demo-app (RPS)
│   ├── ml/                              # collector, trainer, analyzer, redis, PVC, RBAC
│   └── demo/                            # breakable demo app + load generator
├── scripts/                             # deploy-all, port-forward, smoke-test, build-push, clean
├── src/
│   ├── common/                          # settings, PromQL queries, feature engineering
│   ├── collector/                       # Prometheus → feature windows → queue + parquet
│   ├── trainer/                         # IsolationForest + failure classifier, versioned artifacts
│   ├── analyzer/                        # scoring, alerting, RCA enrichment, suggestions KB
│   ├── demo_app/                        # instrumented app with /burn (OOM) and /error endpoints
│   └── loadgen/
└── Makefile
```

## Prerequisites

- `kubectl` (context pointing at your cluster), `helm` 3, `docker`
- A cluster with a default StorageClass (kind/minikube/cloud all qualify)
- Local test cluster optional: `make cluster` (kind v1.30 image)

## Quickstart

```bash
./scripts/deploy-all.sh        # monitoring + Loki + KEDA + ML pipeline + demo app
./scripts/port-forward.sh      # UIs on localhost (runs in background)
```

Then open:

| UI | URL | Notes |
|---|---|---|
| Grafana | http://localhost:3000 | admin / admin — dashboard "AI Ops — Cluster & App Health", plus all bundled K8s dashboards; Loki under Explore |
| Prometheus | http://localhost:9090 | try `monitor_anomaly_score`, `monitor_failure_risk` |
| Alertmanager | http://localhost:9093 | AI alerts appear as `AIPredictedFailure` / `AIAnomalyDetected` / `AIHardSignal` |
| Analyzer API | http://localhost:8088 | `/results` (recent scores), `/rca` (enriched alert reports), `/healthz` |

### Break things on purpose

```bash
./scripts/smoke-test.sh
# Incident 1: error storm — rollout with ERROR_RATE=0.5
# Incident 2: OOMKill  — /burn allocates 600Mi against a 256Mi limit
# then watch:
kubectl -n ai-ops logs -f deployment/ai-analyzer
```

You will see: Prometheus rules firing (`HTTPServerErrorRate`, `ContainerOOMKilled`),
AI hard-signal/predicted alerts, RCA reports joining logs + events, KEDA
scaling the analyzer as the queue grows, and demo-app replicas scaling with
load. Recover with `kubectl -n demo set env deployment/demo-app ERROR_RATE=0.03`.

## How the ML works

1. **Features** (`src/common/features.py`): per pod — CPU/memory vs limits,
   restarts, OOM flags, readiness, network errors/drops; per service — RPS,
   5xx rate, p95 latency; per node — utilization + pressure; per PVC — fill
   ratio. Plus lag features (rolling mean/std of the same entity).
2. **Training** (`src/trainer/train.py`, CronJob every 6h + bootstrap Job):
   - IsolationForest per entity type → anomaly scores; threshold calibrated
     at the 98th percentile of training scores.
   - Failure classifier (HistGradientBoosting) trained on **automatically
     generated labels**: "pod hit a restart/OOM/not-ready within the next
     15 minutes". No manual incident labeling required.
   - Cold start: trains on synthetic data so day-0 you get anomaly + rule
     alerts; the classifier activates once ~300 rows / 25 real positives
     accumulate (about a day of idle history, faster if you run the smoke tests).
   - Artifacts are versioned (`model.joblib` + `model.meta.json`) on a PVC;
     the analyzer hot-reloads on version change.
3. **Scoring** (`src/analyzer/main.py`): every window gets an anomaly score
   (0–1), a failure probability, and "top factors" (which features deviate
   most from the learned baseline — that's the *why*).
4. **Alerting**: three layers — deterministic Prometheus rules, ML anomaly
   detection, ML failure prediction, plus hard signals (restart/OOM/pressure)
   that alert even with no model. Alerts dedupe per entity (15 min) and
   auto-resolve (30 min).
5. **RCA & debugging points**: every alert is enriched with Loki error logs,
   Kubernetes events, and a rule-based knowledge base of concrete `kubectl`
   commands (`src/analyzer/suggestions.py`), then optionally posted to Slack:

```bash
kubectl -n ai-ops create secret generic ai-ops-secrets \
  --from-literal=SLACK_WEBHOOK_URL='https://hooks.slack.com/services/XXX/YYY/ZZZ' \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n ai-ops rollout restart deployment/ai-analyzer
```

## KEDA autoscaling

- `ai-analyzer`: `max(monitor_windows_pending) > 25` → 1–6 replicas
  (backpressure-aware ML serving).
- `demo-app`: RPS `> 40` per replica → 1–8 replicas (no HPA needed).
- Tune thresholds in `k8s/keda/scaledobjects.yaml`; scale behavior (cooldown,
  stabilization) via standard ScaledObject fields.

## Deploying to your existing cluster

Same steps — the deploy script auto-detects kind (loads images into the node)
vs a remote cluster. For a remote cluster push images to your registry first:

```bash
make build-push REG=ghcr.io/<you> TAG=v1
./scripts/deploy-all.sh     # detects non-kind context; skips kind load
# then point workloads at the registry images (done automatically by build-push.sh)
```

Notes for production:
- The 5Gi `ai-ops-data` PVC is `ReadWriteOnce` — on a multi-node cluster use a
  `ReadWriteMany` StorageClass (NFS/EFS/CephFS) or S3-backed artifact storage.
- Increase Prometheus retention (values file) so the trainer has more history.
- The ML services are deliberately small (requests 100m/256Mi) — bump as your
  cluster's pod count grows; the collector emits one window per pod per minute.

## Extending

- **Your own apps**: expose `http_requests_total{status,...}` and
  `http_request_duration_seconds_bucket` (any standard instrumentation) and add
  a ServiceMonitor — anomaly detection covers them automatically; add app
  metrics to the feature set in `src/common/features.py` and retrain.
- **LLM-assisted RCA**: point `enrich.build_rca` output at any LLM endpoint to
  narrate the report; the plumbing (context: logs + events + factors) is already there.
- **More entity types / features**: extend `ALL_COLS` + queries — trainer and
  analyzer pick up new columns automatically on the next run.

## Troubleshooting

| Symptom | Fix |
|---|---|
| Analyzer logs "model reload failed" / rule-only mode | Check the bootstrap job: `kubectl -n ai-ops logs job/ai-trainer-bootstrap` |
| No AI metrics in Prometheus | Check ServiceMonitors: `kubectl get servicemonitor -A`; Prometheus targets page |
| Queue keeps growing | `kubectl get hpa`-equivalent: `kubectl get scaledobject -A`; KEDA controller: `kubectl -n keda logs -l app=keda-operator` |
| Grafana dashboard missing | ConfigMap label check: `kubectl get cm grafana-dashboard-ai-ops -n monitoring --show-labels` |
| No logs in Loki | `kubectl -n monitoring logs -l app.kubernetes.io/name=promtail` |
