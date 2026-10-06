#!/usr/bin/env bash
# Build + push images to a registry and point the cluster at them (remote clusters).
# usage: ./scripts/build-push.sh myregistry.example.com/myprefix [tag]
set -euo pipefail
cd "$(dirname "$0")/.."

REG="${1:?usage: build-push.sh <registry[/prefix]> [tag]}"
TAG="${2:-latest}"

docker build -t "$REG/k8s-ai-ops:$TAG" -f docker/Dockerfile .
docker build -t "$REG/demo-app:$TAG" -f docker/demo-app.Dockerfile .
docker push "$REG/k8s-ai-ops:$TAG"
docker push "$REG/demo-app:$TAG"

kubectl -n ai-ops set image deployment/ai-collector collector="$REG/k8s-ai-ops:$TAG"
kubectl -n ai-ops set image deployment/ai-analyzer analyzer="$REG/k8s-ai-ops:$TAG"
kubectl -n ai-ops set image cronjob/ai-trainer trainer="$REG/k8s-ai-ops:$TAG" 2>/dev/null || \
  kubectl -n ai-ops patch cronjob ai-trainer -p "{\"spec\":{\"jobTemplate\":{\"spec\":{\"template\":{\"spec\":{\"containers\":[{\"name\":\"trainer\",\"image\":\"$REG/k8s-ai-ops:$TAG\"}]}}}}}}"
kubectl -n demo set image deployment/demo-app demo-app="$REG/demo-app:$TAG"
kubectl -n demo set image deployment/loadgen loadgen="$REG/k8s-ai-ops:$TAG"
echo "done: all workloads now use $REG/*:$TAG"
