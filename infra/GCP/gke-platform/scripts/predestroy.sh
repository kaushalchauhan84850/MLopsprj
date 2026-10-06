#!/usr/bin/env bash
# predestroy.sh - run BEFORE `terraform destroy` (destroy.sh does it for you).
#
# Why this exists: Terraform only knows what it created. Kubernetes creates GCP
# resources on its own - load balancers and their k8s-* firewall rules, network
# endpoint groups (NEGs) and persistent disks. They live inside your VPC, so
# deleting the VPC then fails with "resource is already being used", which is
# the usual reason `terraform destroy` ends in an error state.
#
# This script removes them the proper way (through Kubernetes) and waits until
# GCP has actually released them.
#
# What it deletes in the cluster: Gateways, Ingresses, Services of type
# LoadBalancer, workloads (deployments, statefulsets, daemonsets, jobs,
# cronjobs, pods), PersistentVolumeClaims and PersistentVolumes. System
# namespaces (kube-*, gke-*, gmp-*) are left alone.
#
# Usage: ./scripts/predestroy.sh [--yes] [--force]
#   --yes    skip the confirmation prompt
#   --force  continue even if the Kubernetes API cannot be reached
# Exit:    0 = clean, 1 = error/aborted, 3 = finished but GCP still holds some resources

set -euo pipefail
# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

ASSUME_YES=0
export ASSUME_YES
FORCE=0

usage() {
  sed -n '2,24p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while (($#)); do
  case "$1" in
  -y | --yes) ASSUME_YES=1 ;;
  --force) FORCE=1 ;;
  -h | --help)
    usage
    exit 0
    ;;
  *) die "Unknown option: $1 (try --help)" ;;
  esac
  shift
done

load_config
require_cmd gcloud jq

is_system_ns() { [[ "$1" =~ ^(kube-|gke-|gmp-) ]]; }

kdel() {
  kubectl delete "$@" --ignore-not-found --wait=true --timeout=300s ||
    log_warn "kubectl delete $* did not finish cleanly"
}

wait_for_gcp_release() {
  local failed=0
  wait_until "GKE-created load balancer firewall rules (k8s-*) to disappear" 600 15 no_k8s_firewalls || failed=1
  wait_until "GKE-created network endpoint groups to disappear" 600 15 no_negs || failed=1
  return "$failed"
}

finish() {
  if wait_for_gcp_release; then
    log_ok "Pre-destroy cleanup complete. Safe to run: terraform destroy (or ./scripts/destroy.sh)"
    exit 0
  fi
  log_warn "GCP still holds Kubernetes-created resources in ${NETWORK_NAME}."
  log_warn "terraform destroy may fail on the VPC; destroy.sh retries automatically. Details: ./scripts/verifydestroy.sh"
  exit 3
}

log_step "Pre-destroy cleanup: cluster '${CLUSTER_NAME}' in project '${PROJECT_ID}' (${ZONE})"

if ! cluster_exists; then
  log_info "Cluster not found, so there is nothing to clean inside Kubernetes."
  finish
fi

protect="$(gcloud container clusters describe "$CLUSTER_NAME" --zone "$ZONE" \
  --project "$PROJECT_ID" --format='value(deletionProtection)' 2>/dev/null || true)"
if [[ "${protect,,}" == "true" ]]; then
  die "Cluster has deletion protection ON. Set deletion_protection = false in terraform.tfvars, run 'terraform apply', then retry."
fi

require_cmd kubectl
command -v gke-gcloud-auth-plugin >/dev/null 2>&1 ||
  die "gke-gcloud-auth-plugin not found. Install: gcloud components install gke-gcloud-auth-plugin"

# Use a throwaway kubeconfig so the operator's own kubeconfig is never touched.
KUBECONFIG="$(mktemp)"
export KUBECONFIG
trap 'rm -f "$KUBECONFIG"' EXIT

gcloud container clusters get-credentials "$CLUSTER_NAME" --zone "$ZONE" \
  --project "$PROJECT_ID" >/dev/null 2>&1 || die "Could not fetch cluster credentials."

if ! kubectl get namespaces --request-timeout=30s >/dev/null 2>&1; then
  if ((FORCE)); then
    log_warn "Kubernetes API unreachable; --force given, skipping in-cluster cleanup. Load balancers and disks may be left behind."
    finish
  fi
  die "Cannot reach the Kubernetes API. Check authorized_networks (is your current IP allowed?), or use --force to skip in-cluster cleanup."
fi

log_warn "This deletes ALL workloads, PVCs and PVs outside the system namespaces of ${CLUSTER_NAME}."
confirm_project

log_step "1/5 Stop new load balancers: Gateways, Ingresses, LoadBalancer Services"
if kubectl api-resources --api-group=gateway.networking.k8s.io -o name 2>/dev/null | grep -q .; then
  kdel gateways.gateway.networking.k8s.io -A --all
fi
kdel ingress -A --all
kubectl get svc -A -o json |
  jq -r '.items[] | select(.spec.type=="LoadBalancer") | "\(.metadata.namespace)/\(.metadata.name)"' |
  while IFS=/ read -r ns name; do
    kdel svc -n "$ns" "$name"
  done

log_step "2/5 Delete workloads so volumes are no longer in use"
mapfile -t namespaces < <(kubectl get namespaces -o json | jq -r '.items[].metadata.name')
for ns in "${namespaces[@]}"; do
  if is_system_ns "$ns"; then
    continue
  fi
  log_info "Namespace ${ns}"
  kdel deployments,statefulsets,daemonsets,replicasets,jobs,cronjobs,pods -n "$ns" --all
done

log_step "3/5 Delete PersistentVolumeClaims (releases the disks)"
kdel pvc -A --all

log_step "4/5 Delete PersistentVolumes"
kdel pv --all

log_step "5/5 Wait for GCP to release the resources"
finish
