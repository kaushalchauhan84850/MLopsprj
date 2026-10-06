#!/usr/bin/env bash
# One-shot deploy: monitoring stack, Loki, Promtail, KEDA, ML services, demo app.
set -euo pipefail
cd "$(dirname "$0")/.."

IMAGE="${IMAGE:-k8s-ai-ops:dev}"
DEMO_IMAGE="${DEMO_IMAGE:-demo-app:dev}"

echo "==> [1/7] Helm repos"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
helm repo add grafana https://grafana.github.io/helm-charts 2>/dev/null || true
helm repo add kedacore https://kedacore.github.io/charts 2>/dev/null || true
helm repo update

echo "==> [2/7] Namespaces"
kubectl apply -f k8s/00-namespaces.yaml

echo "==> [3/7] Monitoring stack (kube-prometheus-stack + Loki + Promtail + KEDA)"
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  -n monitoring -f k8s/monitoring/kube-prometheus-stack-values.yaml --wait --timeout 10m
helm upgrade --install loki grafana/loki -n monitoring \
  -f k8s/monitoring/loki-values.yaml --wait --timeout 10m
helm upgrade --install promtail grafana/promtail -n monitoring \
  -f k8s/monitoring/promtail-values.yaml --wait --timeout 10m
helm upgrade --install keda kedacore/keda -n keda --create-namespace --wait --timeout 10m

echo "==> [4/7] Build images"
docker build -t "$IMAGE" -f docker/Dockerfile .
docker build -t "$DEMO_IMAGE" -f docker/demo-app.Dockerfile .
CTX="$(kubectl config current-context)"
if [[ "$CTX" == kind-* ]]; then
  echo "    kind cluster detected — loading images"
  kind load docker-image "$IMAGE" "$DEMO_IMAGE" --name "${CTX#kind-}"
fi
# For a remote cluster instead: ./scripts/build-push.sh <registry>

echo "==> [5/7] ML pipeline (collector, trainer, analyzer, redis)"
kubectl apply -f k8s/ml/

echo "==> [6/7] Demo app, alert rules, KEDA autoscaling"
kubectl apply -f k8s/monitoring/prometheus-rules.yaml
kubectl apply -f k8s/demo/
kubectl apply -f k8s/keda/

kubectl create configmap grafana-dashboard-ai-ops \
  --from-file=dashboards/ai-ops-overview.json -n monitoring \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl label configmap grafana-dashboard-ai-ops -n monitoring grafana_dashboard=1 --overwrite

echo "==> [7/7] Waiting for rollouts"
for spec in "redis ai-ops" "ai-collector ai-ops" "ai-analyzer ai-ops" "demo-app demo" "loadgen demo"; do
  set -- $spec
  kubectl rollout status deployment/"$1" -n "$2" --timeout=300s
done
echo "    waiting for bootstrap training job (first ML model)..."
kubectl wait --for=condition=complete job/ai-trainer-bootstrap -n ai-ops --timeout=600s || \
  echo "    (bootstrap trainer still running — the analyzer starts in rule-based mode and hot-loads the model when ready)"

echo ""
echo "Deployed! Next:"
echo "  ./scripts/port-forward.sh   # Grafana http://localhost:3000 (admin/admin), Prometheus :9090, Alertmanager :9093, Analyzer API :8088"
echo "  ./scripts/smoke-test.sh     # trigger incidents and watch AI alerts + RCA reports"
