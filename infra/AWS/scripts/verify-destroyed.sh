#!/usr/bin/env bash
#
# Proves that nothing belonging to the cluster is left in AWS after
# `terraform destroy`. Exits 0 if clean, 1 if anything is left over.
#
# Env (defaults match variables.tf):
#   CLUSTER_NAME=heavy-cluster  AWS_REGION=us-east-1

set -uo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-heavy-cluster}"
AWS_REGION="${AWS_REGION:-us-east-1}"
export AWS_DEFAULT_REGION="$AWS_REGION" AWS_PAGER=""

command -v aws >/dev/null 2>&1 || { echo "aws CLI not found" >&2; exit 2; }
aws sts get-caller-identity >/dev/null 2>&1 || { echo "AWS credentials are not working" >&2; exit 2; }

echo "Checking for leftovers of '$CLUSTER_NAME' in $AWS_REGION ..."

find_leftovers() {
  local found=()

  if aws eks describe-cluster --name "$CLUSTER_NAME" >/dev/null 2>&1; then
    found+=("EKS cluster $CLUSTER_NAME still exists")
  fi

  local lg
  lg="$(aws logs describe-log-groups --log-group-name-prefix "/aws/eks/$CLUSTER_NAME/" \
        --query 'logGroups[].logGroupName' --output text)"
  [[ -n "$lg" ]] && found+=("CloudWatch log group: $lg")

  local arn state
  while read -r arn; do
    [[ -z "$arn" ]] && continue
    # KMS keys can never be deleted instantly; "PendingDeletion" is the final state.
    if [[ "$arn" == *":key/"* ]]; then
      state="$(aws kms describe-key --key-id "$arn" --query 'KeyMetadata.KeyState' --output text 2>/dev/null)"
      [[ "$state" == "PendingDeletion" ]] && continue
    fi
    found+=("$arn")
  done < <(
    {
      aws resourcegroupstaggingapi get-resources --tag-filters "Key=Project,Values=$CLUSTER_NAME" \
        --query 'ResourceTagMappingList[].ResourceARN' --output text
      aws resourcegroupstaggingapi get-resources --tag-filters "Key=kubernetes.io/cluster/$CLUSTER_NAME" \
        --query 'ResourceTagMappingList[].ResourceARN' --output text
      aws resourcegroupstaggingapi get-resources --tag-filters "Key=elbv2.k8s.aws/cluster,Values=$CLUSTER_NAME" \
        --query 'ResourceTagMappingList[].ResourceARN' --output text
    } | tr '\t' '\n' | sed '/^$/d' | sort -u
  )

  printf '%s\n' "${found[@]:-}" | sed '/^$/d'
}

# The tagging API is eventually consistent, so re-check a few times before
# declaring a leftover.
leftovers=""
for attempt in 1 2 3 4; do
  leftovers="$(find_leftovers)"
  [[ -z "$leftovers" ]] && break
  if (( attempt < 4 )); then
    echo "  still seeing resources (attempt $attempt/4), waiting 30s for AWS to catch up ..."
    sleep 30
  fi
done

if [[ -z "$leftovers" ]]; then
  echo "OK: nothing left behind (KMS keys, if any, are in their mandatory 'pending deletion' state)."
  exit 0
fi

echo
echo "LEFTOVERS FOUND:"
sed 's/^/  - /' <<<"$leftovers"
echo
echo "Re-run 'terraform destroy' first. If items remain, delete them in the console or CLI."
exit 1
