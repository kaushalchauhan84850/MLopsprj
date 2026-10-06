#!/usr/bin/env bash
# scripts/lib/common.sh - helpers shared by preflight/predestroy/destroy/verifydestroy.
# Source this file; do not execute it.

if [[ -n "${_GKE_COMMON_LOADED:-}" ]]; then
  return 0
fi
_GKE_COMMON_LOADED=1

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPTS_DIR="${ROOT_DIR}/scripts"
export ROOT_DIR SCRIPTS_DIR

# ----------------------------------------------------------------- output ---
if [[ -t 1 ]]; then
  C_RED=$'\033[31m'
  C_GRN=$'\033[32m'
  C_YEL=$'\033[33m'
  C_BLU=$'\033[34m'
  C_RST=$'\033[0m'
else
  C_RED="" C_GRN="" C_YEL="" C_BLU="" C_RST=""
fi

log_info() { printf '%s[INFO]%s  %s\n' "$C_BLU" "$C_RST" "$*"; }
log_ok() { printf '%s[ OK ]%s  %s\n' "$C_GRN" "$C_RST" "$*"; }
log_warn() { printf '%s[WARN]%s  %s\n' "$C_YEL" "$C_RST" "$*" >&2; }
log_err() { printf '%s[FAIL]%s  %s\n' "$C_RED" "$C_RST" "$*" >&2; }
log_step() { printf '\n%s==> %s%s\n' "$C_BLU" "$*" "$C_RST"; }
die() {
  log_err "$*"
  exit 1
}

require_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "Required command not found: ${c}"
  done
}

# ----------------------------------------------------------------- config ---
# Reads a variable from (in order): TF_VAR_<key> env var, terraform.tfvars,
# then the default passed as $2. Defaults must match variables.tf.
tfvar() {
  local key="$1" default="${2:-}" val="" env_name="TF_VAR_${1}"
  local file="${ROOT_DIR}/terraform.tfvars"
  if [[ -n "${!env_name:-}" ]]; then
    printf '%s' "${!env_name}"
    return 0
  fi
  if [[ -f "$file" ]]; then
    val="$(grep -E "^[[:space:]]*${key}[[:space:]]*=" "$file" | head -n1 |
      sed -E 's/^[^=]*=[[:space:]]*//; s/[[:space:]]*#.*$//; s/^"//; s/"[[:space:]]*$//; s/[[:space:]]+$//')" || true
  fi
  printf '%s' "${val:-$default}"
}

# Sets PROJECT_ID, REGION, ZONE, CLUSTER_NAME, NETWORK_NAME ... Any of them can
# be overridden by exporting the variable before running a script.
load_config() {
  PROJECT_ID="${PROJECT_ID:-$(tfvar project_id)}"
  [[ -n "$PROJECT_ID" ]] || die "project_id is not set. Put it in terraform.tfvars or export PROJECT_ID."
  REGION="${REGION:-$(tfvar region us-east1)}"
  ZONE="${ZONE:-$(tfvar zone us-east1-b)}"
  CLUSTER_NAME="${CLUSTER_NAME:-$(tfvar cluster_name gke-jobs)}"
  NODE_COUNT="${NODE_COUNT:-$(tfvar node_count 3)}"
  MACHINE_TYPE="${MACHINE_TYPE:-$(tfvar machine_type e2-standard-2)}"
  DISK_SIZE_GB="${DISK_SIZE_GB:-$(tfvar disk_size_gb 50)}"
  DISK_TYPE="${DISK_TYPE:-$(tfvar disk_type pd-balanced)}"
  NETWORK_NAME="${CLUSTER_NAME}-vpc"
  SUBNET_NAME="${CLUSTER_NAME}-subnet"
  ROUTER_NAME="${CLUSTER_NAME}-router"
  NODE_SA_ID="${CLUSTER_NAME}-nodes"
  # gcloud filter that matches resources attached to our VPC. The embedded quotes
  # are intentional: gcloud filter regexes must be quoted.
  # shellcheck disable=SC2089
  NET_FILTER="network~\"/${NETWORK_NAME}\$\""
  export PROJECT_ID REGION ZONE CLUSTER_NAME NODE_COUNT MACHINE_TYPE DISK_SIZE_GB DISK_TYPE
  # shellcheck disable=SC2090
  export NETWORK_NAME SUBNET_NAME ROUTER_NAME NODE_SA_ID NET_FILTER
}

# ---------------------------------------------------------------- helpers ---
cluster_exists() {
  gcloud container clusters describe "$CLUSTER_NAME" --zone "$ZONE" \
    --project "$PROJECT_ID" >/dev/null 2>&1
}

# confirm_project: make the operator type the project id before anything destructive.
confirm_project() {
  if [[ "${ASSUME_YES:-0}" == "1" ]]; then
    return 0
  fi
  local answer
  read -r -p "Type the project id (${PROJECT_ID}) to continue: " answer
  [[ "$answer" == "$PROJECT_ID" ]] || die "Aborted: project id did not match."
}

# wait_until DESCRIPTION TIMEOUT_SECONDS INTERVAL_SECONDS COMMAND...
# Polls COMMAND until it succeeds. Returns 1 on timeout.
wait_until() {
  local desc="$1" timeout="$2" interval="$3"
  shift 3
  local waited=0
  until "$@"; do
    if ((waited >= timeout)); then
      log_warn "Timed out after ${timeout}s waiting for: ${desc}"
      return 1
    fi
    log_info "Waiting for ${desc} (${waited}s/${timeout}s)"
    sleep "$interval"
    waited=$((waited + interval))
  done
  log_ok "${desc}"
}

# Conditions used by wait_until: true when nothing GKE created is left in our VPC.
no_k8s_firewalls() {
  [[ -z "$(gcloud compute firewall-rules list --project "$PROJECT_ID" \
    --filter="${NET_FILTER} AND name~\"^k8s-\"" --format='value(name)' 2>/dev/null)" ]]
}

no_negs() {
  [[ -z "$(gcloud compute network-endpoint-groups list --project "$PROJECT_ID" \
    --filter="${NET_FILTER}" --format='value(name)' 2>/dev/null)" ]]
}
