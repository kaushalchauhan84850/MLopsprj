#!/usr/bin/env bash
#
# Checks everything that commonly makes `terraform apply` fail halfway
# (and therefore leaves a half-built cluster to clean up).
#
# Env (defaults match variables.tf):
#   AWS_REGION=us-east-1  NODE_INSTANCE_TYPE=t3.large  NODE_COUNT=3

set -uo pipefail

AWS_REGION="${AWS_REGION:-us-east-1}"
NODE_INSTANCE_TYPE="${NODE_INSTANCE_TYPE:-t3.large}"
NODE_COUNT="${NODE_COUNT:-3}"
export AWS_DEFAULT_REGION="$AWS_REGION" AWS_PAGER=""

failed=0
ok()   { printf '  [ok]   %s\n' "$*"; }
bad()  { printf '  [FAIL] %s\n' "$*"; failed=1; }
note() { printf '  [note] %s\n' "$*"; }

echo "Tools"
for t in terraform aws jq kubectl; do
  if command -v "$t" >/dev/null 2>&1; then ok "$t found"; else bad "$t not found"; fi
done

if command -v terraform >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
  tfv="$(terraform version -json 2>/dev/null | jq -r '.terraform_version')"
  if [[ -n "$tfv" && "$(printf '%s\n1.5.7\n' "$tfv" | sort -V | head -n1)" == "1.5.7" ]]; then
    ok "terraform $tfv (>= 1.5.7 required)"
  else
    bad "terraform ${tfv:-unknown} is older than 1.5.7"
  fi
fi

echo "AWS access"
if ident="$(aws sts get-caller-identity --query Arn --output text 2>&1)"; then
  ok "credentials work: $ident"
else
  bad "AWS credentials are not working: $ident"
fi

echo "Capacity in $AWS_REGION"
vcpus="$(aws ec2 describe-instance-types --instance-types "$NODE_INSTANCE_TYPE" \
  --query 'InstanceTypes[0].VCpuInfo.DefaultVCpus' --output text 2>/dev/null)"
if [[ "$vcpus" =~ ^[0-9]+$ ]]; then
  need=$((vcpus * NODE_COUNT))
  quota="$(aws service-quotas get-service-quota --service-code ec2 --quota-code L-1216C47A \
    --query 'Quota.Value' --output text 2>/dev/null)"
  quota="${quota%.*}"
  if [[ "$quota" =~ ^[0-9]+$ ]]; then
    if (( quota >= need )); then
      ok "On-Demand Standard vCPU quota is $quota; this cluster needs $need ($NODE_COUNT x $vcpus)"
      note "usage by other instances in the account is not subtracted"
    else
      bad "On-Demand Standard vCPU quota is $quota but the cluster needs $need. Request an increase (Service Quotas > EC2 > L-1216C47A)"
    fi
  else
    note "could not read the vCPU quota (needs servicequotas:GetServiceQuota); the cluster needs $need vCPUs"
  fi
else
  bad "instance type $NODE_INSTANCE_TYPE not found in $AWS_REGION"
fi

echo
if (( failed )); then
  echo "Preflight FAILED. Fix the items above before running terraform apply."
  exit 1
fi
echo "Preflight passed."
