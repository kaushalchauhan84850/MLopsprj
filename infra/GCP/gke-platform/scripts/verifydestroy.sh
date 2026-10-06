#!/usr/bin/env bash
# verifydestroy.sh - run AFTER `terraform destroy` to prove nothing is left.
#
# Asks GCP directly (not Terraform) whether anything belonging to this stack
# still exists: Terraform state, the cluster, its VMs and instance groups,
# Kubernetes-created firewall rules and NEGs, the VPC, subnet, router/NAT, the
# node service account and its IAM bindings. It also looks for orphaned
# Kubernetes disks and load balancer forwarding rules (warnings only, because
# those cannot be tied to one cluster with certainty).
#
# Every leftover is printed with the gcloud command that removes it.
#
# Usage: ./scripts/verifydestroy.sh [--strict]
#   --strict  treat the warning-level findings as failures too
# Exit:  0 = clean, 1 = leftovers found, 2 = some check could not be completed

set -euo pipefail
# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

STRICT=0
LEFT=0
SOFT=0
UNKNOWN=0

usage() {
  sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while (($#)); do
  case "$1" in
  --strict) STRICT=1 ;;
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

# run_check SEVERITY LABEL HINT COMMAND...
#   SEVERITY: hard (leftover = failure) or soft (leftover = warning)
#   The command must print one line per resource found, and nothing if none.
run_check() {
  local severity="$1" label="$2" hint="$3"
  shift 3
  local out="" rc=0
  out="$("$@" 2>&1)" || rc=$?

  if ((rc != 0)); then
    # A disabled API or a missing parent means there cannot be any resources.
    if grep -qiE 'has not been used|is not enabled|SERVICE_DISABLED|was not found' <<<"$out"; then
      log_ok "${label}: none"
    else
      log_warn "${label}: could not verify ($(head -n1 <<<"$out"))"
      UNKNOWN=$((UNKNOWN + 1))
    fi
    return 0
  fi

  if [[ -z "${out//[[:space:]]/}" ]]; then
    log_ok "${label}: none"
    return 0
  fi

  if [[ "$severity" == "hard" ]]; then
    log_err "${label}: LEFTOVER"
    LEFT=$((LEFT + 1))
  else
    log_warn "${label}: found (review)"
    SOFT=$((SOFT + 1))
  fi
  while IFS= read -r line; do
    printf '          %s\n' "$line" >&2
  done <<<"$out"
  printf '          fix: %s\n' "$hint" >&2
}

# ----------------------------------------------- soft checks (jq filtered) ---
orphan_disks() {
  gcloud compute disks list --project "$PROJECT_ID" --format=json |
    jq -r --arg c "$CLUSTER_NAME" '.[]
      | select(((.users // []) | length) == 0)
      | select(.name | test("^(pvc-|gke-" + $c + "-)"))
      | .name'
}

k8s_forwarding_rules() {
  gcloud compute forwarding-rules list --project "$PROJECT_ID" --format=json |
    jq -r '.[]
      | select((.description // "") | contains("kubernetes.io/service-name"))
      | .name'
}

terraform_state_resources() {
  if [[ -d "${ROOT_DIR}/.terraform" || -f "${ROOT_DIR}/terraform.tfstate" ]]; then
    terraform -chdir="$ROOT_DIR" state list 2>/dev/null || true
  fi
}

log_step "Verifying that '${CLUSTER_NAME}' in '${PROJECT_ID}' is fully gone"

if command -v terraform >/dev/null 2>&1; then
  run_check hard "Terraform state" \
    "terraform state rm <address>  (only if the real resource is already gone)" \
    terraform_state_resources
else
  log_warn "terraform not installed; skipping the state check"
fi

run_check hard "GKE cluster" \
  "gcloud container clusters delete ${CLUSTER_NAME} --zone ${ZONE} --project ${PROJECT_ID}" \
  gcloud container clusters list --project "$PROJECT_ID" \
  --filter="name=${CLUSTER_NAME}" --format='value(name,location)'

run_check hard "Worker VM instances" \
  "gcloud compute instances delete <name> --zone ${ZONE} --project ${PROJECT_ID}" \
  gcloud compute instances list --project "$PROJECT_ID" \
  --filter="name~\"^gke-${CLUSTER_NAME}-\"" --format='value(name,zone.basename())'

run_check hard "Managed instance groups" \
  "gcloud compute instance-groups managed delete <name> --zone ${ZONE} --project ${PROJECT_ID}" \
  gcloud compute instance-groups managed list --project "$PROJECT_ID" \
  --filter="name~\"^gke-${CLUSTER_NAME}-\"" --format='value(name,zone.basename())'

run_check hard "Network endpoint groups in the VPC" \
  "gcloud compute network-endpoint-groups delete <name> --zone ${ZONE} --project ${PROJECT_ID}" \
  gcloud compute network-endpoint-groups list --project "$PROJECT_ID" \
  --filter="$NET_FILTER" --format='value(name,zone.basename())'

run_check hard "Firewall rules in the VPC" \
  "gcloud compute firewall-rules delete <name> --project ${PROJECT_ID}" \
  gcloud compute firewall-rules list --project "$PROJECT_ID" \
  --filter="$NET_FILTER" --format='value(name)'

run_check hard "Cloud Router / NAT" \
  "gcloud compute routers delete ${ROUTER_NAME} --region ${REGION} --project ${PROJECT_ID}" \
  gcloud compute routers list --project "$PROJECT_ID" \
  --filter="name=${ROUTER_NAME}" --format='value(name,region.basename())'

run_check hard "Subnet" \
  "gcloud compute networks subnets delete ${SUBNET_NAME} --region ${REGION} --project ${PROJECT_ID}" \
  gcloud compute networks subnets list --project "$PROJECT_ID" \
  --filter="name=${SUBNET_NAME}" --format='value(name,region.basename())'

run_check hard "VPC network" \
  "gcloud compute networks delete ${NETWORK_NAME} --project ${PROJECT_ID}" \
  gcloud compute networks list --project "$PROJECT_ID" \
  --filter="name=${NETWORK_NAME}" --format='value(name)'

run_check hard "Node service account" \
  "gcloud iam service-accounts delete ${NODE_SA_ID}@${PROJECT_ID}.iam.gserviceaccount.com --project ${PROJECT_ID}" \
  gcloud iam service-accounts list --project "$PROJECT_ID" \
  --filter="email~\"^${NODE_SA_ID}@\"" --format='value(email)'

run_check hard "IAM role bindings of the node service account" \
  "gcloud projects remove-iam-policy-binding ${PROJECT_ID} --member <member> --role <role>" \
  gcloud projects get-iam-policy "$PROJECT_ID" --flatten='bindings[].members' \
  --filter="bindings.members~\"${NODE_SA_ID}@\"" --format='value(bindings.role,bindings.members)'

run_check soft "Unattached Kubernetes disks (pvc-* / gke-${CLUSTER_NAME}-*)" \
  "gcloud compute disks delete <name> --zone <zone> --project ${PROJECT_ID}  (check first that no other cluster uses it)" \
  orphan_disks

run_check soft "Load balancer forwarding rules created by Kubernetes" \
  "gcloud compute forwarding-rules delete <name> --region <region> --project ${PROJECT_ID}  (may belong to another cluster)" \
  k8s_forwarding_rules

# ---------------------------------------------------------------- summary ---
log_step "Result"
log_info "Google APIs are left enabled on purpose (free; disabling them often breaks destroy)."

if ((LEFT > 0)); then
  log_err "${LEFT} resource group(s) still exist. Use the 'fix' commands above, then re-run this script."
  exit 1
fi
if ((UNKNOWN > 0)); then
  log_warn "${UNKNOWN} check(s) could not be completed (permissions or API errors). Review the warnings above."
  exit 2
fi
if ((SOFT > 0)); then
  if ((STRICT)); then
    log_err "${SOFT} warning-level finding(s) and --strict is set."
    exit 1
  fi
  log_warn "Stack is gone, but ${SOFT} item(s) need a manual look (see above)."
  exit 0
fi
log_ok "Everything is destroyed. Nothing left behind."
