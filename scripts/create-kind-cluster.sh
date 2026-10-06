#!/usr/bin/env bash
# Local test cluster (Docker required).
set -euo pipefail

KIND_NAME="${KIND_NAME:-aiops}"
NODE_IMAGE="${NODE_IMAGE:-kindest/node:v1.30.4}"

kind create cluster --name "$KIND_NAME" --image "$NODE_IMAGE"
kubectl config use-context "kind-$KIND_NAME"
kubectl get nodes
