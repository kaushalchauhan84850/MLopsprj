#!/usr/bin/env bash
# destroy.sh - the one command for tearing everything down.
#
#   1. confirms the project id
#   2. terraform init
#   3. predestroy.sh   (removes load balancers / disks Kubernetes created)
#   4. terraform destroy, retried (GCP releases some resources asynchronously)
#   5. verifydestroy.sh (proves nothing was left behind)
#
# Usage: ./scripts/destroy.sh [--yes] [--force] [--skip-predestroy] [--skip-verify] [--retries N]
#   --yes             skip the confirmation prompt
#   --force           pass --force to predestroy.sh (continue if the K8s API is unreachable)
#   --skip-predestroy do not run predestroy.sh
#   --skip-verify     do not run verifydestroy.sh at the end
#   --retries N       terraform destroy attempts (default 3)
# Exit: 0 = destroyed and verified clean, non-zero = see output.

set -euo pipefail
# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

ASSUME_YES=0
export ASSUME_YES
FORCE=0
SKIP_PRE=0
SKIP_VERIFY=0
MAX_RETRIES=3

usage() {
  sed -n '2,17p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while (($#)); do
  case "$1" in
  -y | --yes) ASSUME_YES=1 ;;
  --force) FORCE=1 ;;
  --skip-predestroy) SKIP_PRE=1 ;;
  --skip-verify) SKIP_VERIFY=1 ;;
  --retries)
    shift
    [[ "${1:-}" =~ ^[0-9]+$ ]] || die "--retries needs a number"
    MAX_RETRIES="$1"
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  *) die "Unknown option: $1 (try --help)" ;;
  esac
  shift
done

load_config
require_cmd terraform gcloud
cd "$ROOT_DIR"

log_step "DESTROY"
log_warn "This permanently deletes the cluster '${CLUSTER_NAME}', its VPC, NAT, node service account and IAM bindings."
log_info "project=${PROJECT_ID} region=${REGION} zone=${ZONE}"
confirm_project

log_step "terraform init"
terraform init -input=false -no-color >/dev/null
log_ok "initialised"

if ((SKIP_PRE == 0)); then
  log_step "Pre-destroy cleanup"
  pre_args=(--yes)
  ((FORCE)) && pre_args+=(--force)
  rc=0
  "${SCRIPTS_DIR}/predestroy.sh" "${pre_args[@]}" || rc=$?
  case "$rc" in
  0) ;;
  3) log_warn "predestroy.sh finished with resources still held by GCP; terraform destroy will be retried." ;;
  *) die "predestroy.sh failed (exit ${rc}). Fix the problem and re-run, or use --skip-predestroy." ;;
  esac
fi

attempt=1
destroyed=0
while ((attempt <= MAX_RETRIES)); do
  log_step "terraform destroy (attempt ${attempt}/${MAX_RETRIES})"
  if terraform destroy -auto-approve -input=false; then
    destroyed=1
    break
  fi
  log_warn "terraform destroy attempt ${attempt} failed."
  if ((attempt < MAX_RETRIES)); then
    log_info "Waiting 60s for GCP to finish releasing resources, then retrying..."
    sleep 60
    "${SCRIPTS_DIR}/predestroy.sh" --yes >/dev/null 2>&1 || true
  fi
  attempt=$((attempt + 1))
done

if ((destroyed == 0)); then
  log_err "terraform destroy still failing after ${MAX_RETRIES} attempts. Checking what is left:"
  "${SCRIPTS_DIR}/verifydestroy.sh" || true
  exit 1
fi

rm -f "${ROOT_DIR}/tfplan"
log_ok "terraform destroy finished"

if ((SKIP_VERIFY)); then
  log_warn "Skipping verification (--skip-verify). Run ./scripts/verifydestroy.sh to confirm nothing is left."
  exit 0
fi

"${SCRIPTS_DIR}/verifydestroy.sh"
