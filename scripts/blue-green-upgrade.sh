#!/usr/bin/env bash
# Upgrade the Aurora Global Database with an RDS Blue/Green Deployment.
#
# 1. create   : build a green copy of the whole global database (both regions) on the
#               target engine version and parameter group, kept in sync by replication
# 2. (you)    : point a test client at the green endpoints and check the app
# 3. switch   : switchover with guardrails; endpoints keep their names, typically < 1 min
# 4. cleanup  : delete the deployment record and the old blue clusters
#
# Usage:
#   scripts/blue-green-upgrade.sh create  <target-engine-version> <target-cluster-parameter-group>
#   scripts/blue-green-upgrade.sh status
#   scripts/blue-green-upgrade.sh switch
#   scripts/blue-green-upgrade.sh cleanup
#
# Run from the repo root after `terraform apply`. Uses the primary region from Terraform outputs.
set -euo pipefail

cd "$(dirname "$0")/../stack"
REGION=$(terraform output -json restore_test_inputs | jq -r .region)
GLOBAL_ID=$(terraform output -raw global_cluster_id)
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
# Global cluster ARNs have no region.
SOURCE_ARN="arn:aws:rds::${ACCOUNT}:global-cluster:${GLOBAL_ID}"
NAME="${GLOBAL_ID}-bg"

bg_id() {
  aws rds describe-blue-green-deployments --region "$REGION" \
    --filters "Name=blue-green-deployment-name,Values=${NAME}" \
    --query 'BlueGreenDeployments[0].BlueGreenDeploymentIdentifier' --output text
}

wait_for() {
  local want="$1" status
  for _ in $(seq 1 180); do
    status=$(aws rds describe-blue-green-deployments --region "$REGION" \
      --blue-green-deployment-identifier "$(bg_id)" \
      --query 'BlueGreenDeployments[0].Status' --output text)
    echo "$(date -u +%H:%M:%S) status=${status}"
    [[ "$status" == "$want" ]] && return 0
    [[ "$status" == *FAILED* || "$status" == "INVALID_CONFIGURATION" ]] && { echo "stopped: $status" >&2; return 1; }
    sleep 30
  done
  echo "timed out waiting for $want" >&2
  return 1
}

case "${1:-}" in
  create)
    TARGET_VERSION="${2:?target engine version, for example 17.4}"
    TARGET_PG="${3:?target cluster parameter group name}"
    aws rds create-blue-green-deployment --region "$REGION" \
      --blue-green-deployment-name "$NAME" \
      --source "$SOURCE_ARN" \
      --target-engine-version "$TARGET_VERSION" \
      --target-db-cluster-parameter-group-name "$TARGET_PG" \
      --tags Key=ManagedBy,Value=blue-green-script
    wait_for AVAILABLE
    echo "Green is ready. Test it before running: $0 switch"
    aws rds describe-blue-green-deployments --region "$REGION" \
      --blue-green-deployment-identifier "$(bg_id)" \
      --query 'BlueGreenDeployments[0].SwitchoverDetails' --output table
    ;;
  status)
    aws rds describe-blue-green-deployments --region "$REGION" \
      --blue-green-deployment-identifier "$(bg_id)" --output table
    ;;
  switch)
    # Guardrails: RDS refuses the switchover if replica lag or long-running writes would make
    # it unsafe. The timeout caps how long writes are blocked.
    aws rds switchover-blue-green-deployment --region "$REGION" \
      --blue-green-deployment-identifier "$(bg_id)" \
      --switchover-timeout 300
    wait_for SWITCHOVER_COMPLETED
    echo "Switched. Run the restore test and the app check, then: $0 cleanup"
    ;;
  cleanup)
    # After a switchover the green clusters are production, so only the deployment record is
    # deleted here. The old blue clusters are renamed with an -old1 suffix; delete them once
    # you are sure you will not need them. Then set aurora_engine_version and
    # aurora_parameter_group_major in terraform.tfvars to the new version, so the next
    # apply matches what is running.
    aws rds delete-blue-green-deployment --region "$REGION" \
      --blue-green-deployment-identifier "$(bg_id)"
    echo "Deployment record deleted. List old clusters with:"
    echo "  aws rds describe-db-clusters --region $REGION --query \"DBClusters[?contains(DBClusterIdentifier,'-old1')].DBClusterIdentifier\""
    ;;
  *)
    sed -n '2,16p' "$0"
    exit 1
    ;;
esac
