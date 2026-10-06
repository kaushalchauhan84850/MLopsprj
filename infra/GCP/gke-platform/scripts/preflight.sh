#!/usr/bin/env bash
# preflight.sh - run BEFORE `terraform apply`. Catches the problems that would
# otherwise surface halfway through an apply and leave a half-built stack that
# is painful to destroy.
#
# Checks: tools and versions, gcloud login + application-default credentials,
# project and billing, region/zone/machine type, CPU and disk quota, name
# collisions with resources Terraform does not own, then terraform fmt, init,
# validate and plan.
#
# Usage: ./scripts/preflight.sh [--no-plan]
# Exit:  0 = ready to apply, 1 = at least one check failed.

set -euo pipefail
# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

SKIP_PLAN=0
FAILS=0
WARNS=0

usage() {
  sed -n '2,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while (($#)); do
  case "$1" in
  --no-plan) SKIP_PLAN=1 ;;
  -h | --help)
    usage
    exit 0
    ;;
  *) die "Unknown option: $1 (try --help)" ;;
  esac
  shift
done

pass() { log_ok "$*"; }
fail() {
  log_err "$*"
  FAILS=$((FAILS + 1))
}
warn() {
  log_warn "$*"
  WARNS=$((WARNS + 1))
}

# version_ge A B -> true when A >= B (dotted versions)
version_ge() {
  [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" == "$2" ]]
}

# ------------------------------------------------------------------ tools ---
log_step "Tooling"
MISSING=0
for c in terraform gcloud jq; do
  if command -v "$c" >/dev/null 2>&1; then
    pass "${c} is installed"
  else
    fail "${c} is not installed"
    MISSING=1
  fi
done
((MISSING == 0)) || die "Install the missing tools above, then re-run."

if command -v kubectl >/dev/null 2>&1; then
  pass "kubectl is installed"
else
  warn "kubectl not found (needed to use the cluster and for predestroy.sh)"
fi
if command -v gke-gcloud-auth-plugin >/dev/null 2>&1; then
  pass "gke-gcloud-auth-plugin is installed"
else
  warn "gke-gcloud-auth-plugin not found. Install: gcloud components install gke-gcloud-auth-plugin"
fi

tf_ver="$(terraform version -json 2>/dev/null | jq -r '.terraform_version' 2>/dev/null || true)"
if [[ -n "$tf_ver" ]] && version_ge "$tf_ver" "1.9.0"; then
  pass "Terraform ${tf_ver} (>= 1.9.0 required)"
else
  fail "Terraform ${tf_ver:-unknown} found; version 1.9.0 or newer is required"
fi

# ----------------------------------------------------------------- config ---
log_step "Configuration"
load_config
log_info "project=${PROJECT_ID} region=${REGION} zone=${ZONE} cluster=${CLUSTER_NAME}"
log_info "workers=${NODE_COUNT} x ${MACHINE_TYPE} (${DISK_SIZE_GB}GB ${DISK_TYPE})"

if [[ "$ZONE" == "${REGION}-"* ]]; then
  pass "Zone ${ZONE} is inside region ${REGION}"
else
  fail "Zone ${ZONE} is not inside region ${REGION}"
fi

if [[ "$NODE_COUNT" =~ ^[0-9]+$ ]] && ((NODE_COUNT >= 1)); then
  pass "node_count = ${NODE_COUNT}"
else
  fail "node_count must be a positive integer (got '${NODE_COUNT}')"
fi

if [[ -f "${ROOT_DIR}/terraform.tfvars" ]]; then
  pass "terraform.tfvars found"
  if grep -q '0\.0\.0\.0/0' "${ROOT_DIR}/terraform.tfvars" ||
    ! grep -q '^[[:space:]]*authorized_networks' "${ROOT_DIR}/terraform.tfvars"; then
    warn "The Kubernetes API is open to the whole internet. Set authorized_networks to your own IP (x.x.x.x/32)."
  fi
else
  warn "terraform.tfvars not found; using TF_VAR_* variables or defaults. Copy terraform.tfvars.example."
fi

# ------------------------------------------------------------ GCP account ---
log_step "Google Cloud access"
account="$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null | head -n1 || true)"
if [[ -n "$account" ]]; then
  pass "gcloud is logged in as ${account}"
else
  fail "gcloud is not logged in. Run: gcloud auth login"
fi

if gcloud auth application-default print-access-token >/dev/null 2>&1; then
  pass "Application Default Credentials are set (used by Terraform)"
else
  fail "No Application Default Credentials. Run: gcloud auth application-default login"
fi

project_state="$(gcloud projects describe "$PROJECT_ID" --format='value(lifecycleState)' 2>/dev/null || true)"
if [[ "$project_state" == "ACTIVE" ]]; then
  pass "Project ${PROJECT_ID} exists and is ACTIVE"
else
  fail "Project ${PROJECT_ID} not found or not active (state='${project_state:-none}')"
fi

billing="$(gcloud billing projects describe "$PROJECT_ID" --format='value(billingEnabled)' 2>/dev/null || true)"
if [[ "$billing" == "True" ]]; then
  pass "Billing is enabled"
else
  fail "Billing is not enabled on ${PROJECT_ID} (GKE cannot be created without it)"
fi

# --------------------------------------------- compute-dependent checks ---
log_step "Capacity and name collisions"
compute_enabled="$(gcloud services list --enabled --project "$PROJECT_ID" \
  --filter='config.name=compute.googleapis.com' --format='value(config.name)' 2>/dev/null || true)"

if [[ -z "$compute_enabled" ]]; then
  warn "Compute Engine API is not enabled yet; Terraform will enable it. Skipping machine type, quota and collision checks."
else
  if gcloud compute machine-types describe "$MACHINE_TYPE" --zone "$ZONE" \
    --project "$PROJECT_ID" >/dev/null 2>&1; then
    pass "Machine type ${MACHINE_TYPE} is available in ${ZONE}"
  else
    fail "Machine type ${MACHINE_TYPE} is not available in ${ZONE}"
  fi

  regions_json="$(gcloud compute regions describe "$REGION" --project "$PROJECT_ID" --format=json 2>/dev/null || true)"

  # +1 node of headroom because surge upgrades briefly run an extra node.
  vcpus="${MACHINE_TYPE##*-}"
  if [[ "$vcpus" =~ ^[0-9]+$ ]] && [[ -n "$regions_json" ]]; then
    needed=$(((NODE_COUNT + 1) * vcpus))
    avail="$(jq -r '.quotas[] | select(.metric=="CPUS") | (.limit - .usage) | floor' <<<"$regions_json" | head -n1)"
    if [[ -n "$avail" ]] && ((avail >= needed)); then
      pass "CPU quota in ${REGION}: ${avail} free, ${needed} needed (incl. upgrade headroom)"
    else
      fail "CPU quota in ${REGION}: ${avail:-unknown} free, ${needed} needed. Request more quota or use a smaller machine_type/node_count."
    fi
  else
    warn "Could not work out vCPUs for ${MACHINE_TYPE}; skipping CPU quota check."
  fi

  if [[ "$DISK_TYPE" == "pd-standard" ]]; then
    disk_metric="DISKS_TOTAL_GB"
  else
    disk_metric="SSD_TOTAL_GB"
  fi
  if [[ -n "$regions_json" ]]; then
    disk_needed=$(((NODE_COUNT + 1) * DISK_SIZE_GB))
    disk_avail="$(jq -r --arg m "$disk_metric" '.quotas[] | select(.metric==$m) | (.limit - .usage) | floor' <<<"$regions_json" | head -n1)"
    if [[ -n "$disk_avail" ]] && ((disk_avail >= disk_needed)); then
      pass "${disk_metric} quota: ${disk_avail} GB free, ${disk_needed} GB needed"
    else
      warn "${disk_metric} quota: ${disk_avail:-unknown} GB free, ${disk_needed} GB needed"
    fi
  fi
fi

# ------------------------------------------------------------- terraform ---
log_step "Terraform"
cd "$ROOT_DIR"

if terraform fmt -check -recursive >/dev/null 2>&1; then
  pass "terraform fmt: formatting is clean"
else
  warn "terraform fmt would change files. Run: terraform fmt -recursive"
fi

if init_out="$(terraform init -input=false -no-color 2>&1)"; then
  pass "terraform init"
else
  fail "terraform init failed"
  printf '%s\n' "$init_out" | tail -n 15 >&2
fi

if val_out="$(terraform validate -no-color 2>&1)"; then
  pass "terraform validate"
else
  fail "terraform validate failed"
  printf '%s\n' "$val_out" | tail -n 20 >&2
fi

# Collisions: a resource with our name that Terraform does not own makes apply fail.
in_state() { terraform state list 2>/dev/null | grep -q "$1"; }

if [[ -n "$compute_enabled" ]]; then
  if cluster_exists && ! in_state 'google_container_cluster'; then
    fail "A GKE cluster named ${CLUSTER_NAME} already exists in ${ZONE} but is not in this Terraform state. Pick another cluster_name."
  else
    pass "No unmanaged cluster named ${CLUSTER_NAME}"
  fi
  if gcloud compute networks describe "$NETWORK_NAME" --project "$PROJECT_ID" >/dev/null 2>&1 &&
    ! in_state 'google_compute_network'; then
    fail "A VPC named ${NETWORK_NAME} already exists but is not in this Terraform state. Pick another cluster_name."
  else
    pass "No unmanaged VPC named ${NETWORK_NAME}"
  fi
fi

if ((SKIP_PLAN == 0)) && ((FAILS == 0)); then
  if plan_out="$(terraform plan -input=false -no-color -out=tfplan 2>&1)"; then
    pass "terraform plan: $(grep -E '^(Plan:|No changes)' <<<"$plan_out" | head -n1)"
  else
    fail "terraform plan failed"
    printf '%s\n' "$plan_out" | tail -n 25 >&2
  fi
elif ((SKIP_PLAN == 0)); then
  warn "Skipping terraform plan because earlier checks failed."
fi

# ---------------------------------------------------------------- summary ---
log_step "Summary"
if ((FAILS > 0)); then
  log_err "${FAILS} check(s) failed, ${WARNS} warning(s). Fix the failures above before running terraform apply."
  exit 1
fi
log_ok "All checks passed (${WARNS} warning(s)). Next: terraform apply"
if [[ -f "${ROOT_DIR}/tfplan" ]]; then
  log_info "A saved plan is in ./tfplan: terraform apply tfplan"
fi
