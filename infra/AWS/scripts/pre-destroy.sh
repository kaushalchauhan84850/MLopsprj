#!/usr/bin/env bash
#
# Pre-destroy cleanup for the EKS cluster. Run automatically by Terraform
# (see terraform_data.pre_destroy_cleanup in main.tf) BEFORE the cluster and
# VPC are destroyed. Safe to run repeatedly, and safe if the cluster or VPC no
# longer exist.
#
# Required env: CLUSTER_NAME, AWS_REGION, VPC_ID
# Optional env: SKIP_K8S_CLEANUP=1   skip the in-cluster phase (use only if
#                                    nothing was ever deployed to the cluster)

set -uo pipefail

CLUSTER_NAME="${CLUSTER_NAME:?CLUSTER_NAME is required}"
AWS_REGION="${AWS_REGION:?AWS_REGION is required}"
VPC_ID="${VPC_ID:?VPC_ID is required}"
export AWS_DEFAULT_REGION="$AWS_REGION" AWS_PAGER=""

WAIT_LB_SECONDS="${WAIT_LB_SECONDS:-900}"
WAIT_PV_SECONDS="${WAIT_PV_SECONDS:-600}"
WAIT_NODES_SECONDS="${WAIT_NODES_SECONDS:-1200}"
WAIT_ENI_SECONDS="${WAIT_ENI_SECONDS:-300}"

log()  { printf '[pre-destroy] %s\n' "$*"; }
warn() { printf '[pre-destroy] WARNING: %s\n' "$*" >&2; }
die()  { printf '[pre-destroy] ERROR: %s\n' "$*" >&2; exit 1; }

command -v aws >/dev/null 2>&1 || die "aws CLI not found"
command -v jq  >/dev/null 2>&1 || die "jq not found"

KUBECONFIG_FILE="$(mktemp)"
trap 'rm -f "$KUBECONFIG_FILE"' EXIT

# wait_until <timeout_seconds> <description> <command...>
# Re-runs the command every 15s until it succeeds or the timeout expires.
wait_until() {
  local timeout="$1" desc="$2"
  shift 2
  local waited=0
  until "$@"; do
    if (( waited >= timeout )); then
      warn "timed out after ${timeout}s waiting for: ${desc}"
      return 1
    fi
    sleep 15
    waited=$((waited + 15))
  done
  return 0
}

# ---------------------------------------------------------------------------
# What still exists?
# ---------------------------------------------------------------------------
if ! out="$(aws ec2 describe-vpcs --vpc-ids "$VPC_ID" 2>&1)"; then
  if grep -q 'InvalidVpcID.NotFound' <<<"$out"; then
    log "VPC $VPC_ID no longer exists; nothing to clean up."
    exit 0
  fi
  die "cannot describe VPC $VPC_ID: $out"
fi

cluster_exists=true
if ! out="$(aws eks describe-cluster --name "$CLUSTER_NAME" 2>&1)"; then
  if grep -q 'ResourceNotFoundException' <<<"$out"; then
    cluster_exists=false
    log "Cluster $CLUSTER_NAME no longer exists; skipping in-cluster steps."
  else
    die "cannot describe cluster $CLUSTER_NAME: $out"
  fi
fi

# ---------------------------------------------------------------------------
# Phase 1: Kubernetes objects that own AWS resources
# ---------------------------------------------------------------------------
no_pvs() { [[ -z "$(kubectl get pv -o name 2>/dev/null)" ]]; }

cleanup_kubernetes() {
  command -v kubectl >/dev/null 2>&1 \
    || die "kubectl not found. Install it, or run with SKIP_K8S_CLEANUP=1 if nothing was deployed."

  aws eks update-kubeconfig --name "$CLUSTER_NAME" --kubeconfig "$KUBECONFIG_FILE" >/dev/null \
    || die "could not build a kubeconfig for $CLUSTER_NAME"
  export KUBECONFIG="$KUBECONFIG_FILE"

  kubectl get ns >/dev/null 2>&1 \
    || die "cannot reach the Kubernetes API. Is your current IP in api_allowed_cidrs? (Or run with SKIP_K8S_CLEANUP=1 if nothing was deployed.)"

  log "Deleting Ingresses and LoadBalancer Services (this releases the AWS load balancers)"
  kubectl delete ingress --all --all-namespaces --wait=true --timeout=10m \
    || warn "some Ingresses could not be deleted"
  kubectl get svc --all-namespaces -o json \
    | jq -r '.items[] | select(.spec.type=="LoadBalancer") | "\(.metadata.namespace) \(.metadata.name)"' \
    | while read -r ns name; do
        kubectl delete svc "$name" -n "$ns" --wait=true --timeout=10m \
          || warn "could not delete Service $ns/$name"
      done

  log "Deleting workloads outside system namespaces (so volumes can detach)"
  local ns
  for ns in $(kubectl get ns -o jsonpath='{.items[*].metadata.name}'); do
    case "$ns" in
      kube-system|kube-public|kube-node-lease) continue ;;
    esac
    kubectl delete cronjob,job,deployment,statefulset,daemonset,replicaset,pod \
      --all -n "$ns" --wait=true --timeout=5m \
      || warn "some workloads in namespace $ns could not be deleted"
  done

  log "Deleting PersistentVolumeClaims (releases EBS volumes whose reclaimPolicy is Delete)"
  kubectl delete pvc --all --all-namespaces --wait=true --timeout=10m \
    || warn "some PVCs could not be deleted"
  wait_until "$WAIT_PV_SECONDS" "PersistentVolumes to be deleted" no_pvs \
    || warn "PersistentVolumes still exist (reclaimPolicy Retain?): $(kubectl get pv -o name 2>/dev/null | tr '\n' ' ')"
}

if [[ "$cluster_exists" == true ]]; then
  if [[ "${SKIP_K8S_CLEANUP:-0}" == "1" ]]; then
    warn "SKIP_K8S_CLEANUP=1: skipping in-cluster cleanup"
  else
    cleanup_kubernetes
  fi
fi

# ---------------------------------------------------------------------------
# Phase 2: load balancers, target groups and Kubernetes-created security groups
# ---------------------------------------------------------------------------
vpc_lbs() {
  aws elbv2 describe-load-balancers \
    --query "LoadBalancers[?VpcId=='$VPC_ID'].LoadBalancerArn" --output text 2>/dev/null \
    | tr '\t' '\n' | sed '/^$/d;s/^/v2 /'
  aws elb describe-load-balancers \
    --query "LoadBalancerDescriptions[?VPCId=='$VPC_ID'].LoadBalancerName" --output text 2>/dev/null \
    | tr '\t' '\n' | sed '/^$/d;s/^/classic /'
}
no_lbs() { [[ -z "$(vpc_lbs)" ]]; }

log "Waiting for load balancers in $VPC_ID to disappear"
if ! wait_until "$WAIT_LB_SECONDS" "load balancers to disappear" no_lbs; then
  warn "force-deleting load balancers still present in the (dedicated) VPC"
  while read -r kind id; do
    [[ -z "${id:-}" ]] && continue
    if [[ "$kind" == "v2" ]]; then
      aws elbv2 delete-load-balancer --load-balancer-arn "$id" || warn "could not delete $id"
    else
      aws elb delete-load-balancer --load-balancer-name "$id" || warn "could not delete $id"
    fi
  done < <(vpc_lbs)
  wait_until 300 "load balancers to disappear after force delete" no_lbs \
    || die "load balancers still exist in $VPC_ID; delete them manually and re-run"
fi

for tg in $(aws elbv2 describe-target-groups \
    --query "TargetGroups[?VpcId=='$VPC_ID'].TargetGroupArn" --output text 2>/dev/null); do
  aws elbv2 delete-target-group --target-group-arn "$tg" >/dev/null 2>&1 \
    && log "deleted target group $tg" || warn "could not delete target group $tg"
done

# Security groups created by the in-tree cloud provider / AWS LB controller are
# named k8s-*. The EKS module's own groups are not, so they are untouched here.
delete_k8s_sgs() {
  local sg rc=0
  for sg in $(aws ec2 describe-security-groups \
      --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=k8s-*" \
      --query 'SecurityGroups[].GroupId' --output text); do
    if aws ec2 delete-security-group --group-id "$sg" >/dev/null 2>&1; then
      log "deleted security group $sg"
    else
      rc=1
    fi
  done
  return "$rc"
}
wait_until 300 "Kubernetes-created security groups to be deletable" delete_k8s_sgs \
  || warn "some k8s-* security groups remain; they will be reported by verify-destroyed.sh"

# ---------------------------------------------------------------------------
# Phase 3: scale worker nodes to zero so their network interfaces are released
# BEFORE Terraform tries to delete the security groups and subnets.
# ---------------------------------------------------------------------------
no_instances() {
  [[ -z "$(aws ec2 describe-instances \
    --filters "Name=tag:eks:cluster-name,Values=$CLUSTER_NAME" \
              "Name=instance-state-name,Values=pending,running,stopping,stopped,shutting-down" \
    --query 'Reservations[].Instances[].InstanceId' --output text)" ]]
}

if [[ "$cluster_exists" == true ]]; then
  for ng in $(aws eks list-nodegroups --cluster-name "$CLUSTER_NAME" --query 'nodegroups[]' --output text); do
    log "Scaling node group $ng to 0"
    aws eks update-nodegroup-config --cluster-name "$CLUSTER_NAME" --nodegroup-name "$ng" \
      --scaling-config minSize=0,desiredSize=0 >/dev/null \
      || warn "could not scale node group $ng (it may already be updating or deleting)"
  done
fi

log "Waiting for worker instances of $CLUSTER_NAME to terminate"
wait_until "$WAIT_NODES_SECONDS" "worker instances to terminate" no_instances \
  || warn "worker instances are still running; Terraform will terminate them next"

# ---------------------------------------------------------------------------
# Phase 4: sweep orphaned VPC CNI network interfaces ("available" = detached,
# not in use). A known VPC CNI race can leak these when nodes terminate, and
# they block deletion of security groups and subnets.
# ---------------------------------------------------------------------------
sweep_enis() {
  local ids eni left
  ids="$( {
      aws ec2 describe-network-interfaces \
        --filters "Name=vpc-id,Values=$VPC_ID" "Name=status,Values=available" \
                  "Name=tag-key,Values=cluster.k8s.amazonaws.com/name" \
        --query 'NetworkInterfaces[].NetworkInterfaceId' --output text
      aws ec2 describe-network-interfaces \
        --filters "Name=vpc-id,Values=$VPC_ID" "Name=status,Values=available" \
                  "Name=description,Values=aws-K8S-*" \
        --query 'NetworkInterfaces[].NetworkInterfaceId' --output text
    } | tr '\t' '\n' | sed '/^$/d' | sort -u )"
  for eni in $ids; do
    if aws ec2 delete-network-interface --network-interface-id "$eni" >/dev/null 2>&1; then
      log "deleted orphaned network interface $eni"
    fi
  done
  left="$(aws ec2 describe-network-interfaces \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=status,Values=available" \
    --query 'NetworkInterfaces[].NetworkInterfaceId' --output text)"
  [[ -z "$left" ]]
}

log "Sweeping orphaned network interfaces"
wait_until "$WAIT_ENI_SECONDS" "orphaned network interfaces to be gone" sweep_enis \
  || warn "some detached network interfaces remain in $VPC_ID"

log "Cleanup finished. Terraform will now destroy the cluster and network."
