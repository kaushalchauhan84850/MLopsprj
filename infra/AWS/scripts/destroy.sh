#!/usr/bin/env bash
#
# terraform destroy + proof that nothing was left behind.
# Extra arguments are passed to terraform destroy (e.g. -auto-approve).

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

# Read these from state BEFORE destroying (outputs vanish afterwards).
CLUSTER_NAME="$(terraform output -raw cluster_name 2>/dev/null || true)"
AWS_REGION="$(terraform output -raw region 2>/dev/null || true)"
export CLUSTER_NAME="${CLUSTER_NAME:-heavy-cluster}"
export AWS_REGION="${AWS_REGION:-us-east-1}"

terraform destroy "$@" || {
  echo
  echo "terraform destroy failed. Run it again: the cleanup step is safe to repeat."
  exit 1
}

echo
exec ./scripts/verify-destroyed.sh
