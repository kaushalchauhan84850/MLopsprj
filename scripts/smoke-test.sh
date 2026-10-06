#!/usr/bin/env bash
# Trigger realistic incidents against the demo app and watch the AI pipeline react.
set -euo pipefail

echo "==> Incident 1: error storm (5xx rate 50%) via rollout"
kubectl -n demo set env deployment/demo-app ERROR_RATE=0.5
kubectl -n demo rollout status deployment/demo-app --timeout=120s

echo "==> Incident 2: memory burn -> OOMKill on one pod"
POD="$(kubectl -n demo get pod -l app.kubernetes.io/name=demo-app -o jsonpath='{.items[0].metadata.name}')"
echo "    burning memory in $POD (limit is 256Mi)"
kubectl -n demo exec "$POD" -- python -c "
import urllib.request
try:
    urllib.request.urlopen('http://localhost:8080/burn?mb=600&seconds=300', timeout=3)
except Exception:
    pass" || true

echo ""
echo "Incidents triggered. Watch the pipeline react:"
echo "  kubectl -n ai-ops logs -f deployment/ai-analyzer      # alerts + RCA enrichment"
echo "  kubectl -n ai-ops logs -f deployment/ai-collector     # feature windows"
echo "  open http://localhost:8088/results  and  http://localhost:8088/rca   (./scripts/port-forward.sh)"
echo "  Alertmanager UI: http://localhost:9093"
echo ""
echo "Recover with:"
echo "  kubectl -n demo set env deployment/demo-app ERROR_RATE=0.03"
