#!/usr/bin/env bash
# Port-forward every UI/API to localhost (runs in background).
set -euo pipefail

pkill -f "kubectl port-forward.*aiops-forward" 2>/dev/null || true

echo "Grafana      http://localhost:3000   (admin / admin)"
echo "Prometheus   http://localhost:9090"
echo "Alertmanager http://localhost:9093"
echo "Analyzer API http://localhost:8088  (/results /rca /healthz)"

kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80 >/dev/null 2>&1 &
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090 >/dev/null 2>&1 &
kubectl port-forward -n monitoring svc/kube-prometheus-stack-alertmanager 9093:9093 >/dev/null 2>&1 &
kubectl port-forward -n ai-ops svc/ai-analyzer 8088:8080 >/dev/null 2>&1 &
wait
