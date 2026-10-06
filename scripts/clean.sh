#!/usr/bin/env bash
# Remove everything this repo installed (keeps the cluster itself).
set -euo pipefail

helm uninstall promtail loki kube-prometheus-stack -n monitoring 2>/dev/null || true
helm uninstall keda -n keda 2>/dev/null || true
kubectl delete namespace ai-ops demo monitoring keda --ignore-not-found
echo "cleaned."
