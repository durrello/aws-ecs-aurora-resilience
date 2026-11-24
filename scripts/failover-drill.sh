#!/usr/bin/env bash
# Regional failover drill for the two-region stack.
#
#   scripts/failover-drill.sh switchover   planned: promote the secondary region with no data
#                                          loss (Aurora global switchover), scale up its ECS
#                                          service. Use this for drills and region moves.
#   scripts/failover-drill.sh failover     unplanned: the primary region is down. Promotes the
#                                          secondary with possible loss of the last seconds of
#                                          writes (allow-data-loss). Only for a real outage.
#   scripts/failover-drill.sh status       show which cluster is the writer and task counts.
#
# Each run prints timestamps so you can record the measured recovery time.
set -euo pipefail

cd "$(dirname "$0")/../stack"
GLOBAL_ID=$(terraform output -raw global_cluster_id)
PRIMARY_REGION=$(terraform output -json restore_test_inputs | jq -r .region)
SECONDARY_ARN=$(terraform output -raw secondary_cluster_arn)
SECONDARY_REGION=$(cut -d: -f4 <<<"$SECONDARY_ARN")
ECS_JSON=$(terraform output -json ecs)
SEC_CLUSTER=$(jq -r .secondary.cluster <<<"$ECS_JSON")
SEC_SERVICE=$(jq -r .secondary.service <<<"$ECS_JSON")
TASKS="${TASKS:-2}"

log() { echo "$(date -u +%H:%M:%S) $*"; }

writer() {
  aws rds describe-global-clusters --region "$PRIMARY_REGION" --global-cluster-identifier "$GLOBAL_ID" \
    --query 'GlobalClusters[0].GlobalClusterMembers[?IsWriter].DBClusterArn' --output text
}

scale_standby() {
  log "Scaling ${SEC_SERVICE} in ${SECONDARY_REGION} to ${TASKS} tasks"
  aws application-autoscaling register-scalable-target --region "$SECONDARY_REGION" \
    --service-namespace ecs --scalable-dimension ecs:service:DesiredCount \
    --resource-id "service/${SEC_CLUSTER}/${SEC_SERVICE}" \
    --min-capacity "$TASKS" --max-capacity 6 >/dev/null
  aws ecs update-service --region "$SECONDARY_REGION" --cluster "$SEC_CLUSTER" \
    --service "$SEC_SERVICE" --desired-count "$TASKS" >/dev/null
  aws ecs wait services-stable --region "$SECONDARY_REGION" --cluster "$SEC_CLUSTER" --services "$SEC_SERVICE"
  log "Standby service stable"
}

wait_writer() {
  for _ in $(seq 1 120); do
    [[ "$(writer)" == "$SECONDARY_ARN" ]] && { log "Writer is now ${SECONDARY_ARN}"; return 0; }
    sleep 10
  done
  echo "writer did not move" >&2
  return 1
}

case "${1:-}" in
  status)
    log "Writer: $(writer)"
    aws ecs describe-services --region "$SECONDARY_REGION" --cluster "$SEC_CLUSTER" \
      --services "$SEC_SERVICE" --query 'services[0].[desiredCount,runningCount]' --output text
    ;;
  switchover)
    START=$(date +%s)
    scale_standby
    log "Starting global switchover to ${SECONDARY_REGION}"
    aws rds switchover-global-cluster --region "$PRIMARY_REGION" \
      --global-cluster-identifier "$GLOBAL_ID" --target-db-cluster-identifier "$SECONDARY_ARN" >/dev/null
    wait_writer
    log "Drill complete in $(( $(date +%s) - START ))s. Route 53 moves traffic once the primary health check fails, or update DNS for a planned move."
    ;;
  failover)
    read -r -p "Unplanned failover can lose the most recent writes. Type FAILOVER to continue: " ok
    [[ "$ok" == "FAILOVER" ]] || exit 1
    START=$(date +%s)
    log "Starting global failover to ${SECONDARY_REGION}"
    aws rds failover-global-cluster --region "$SECONDARY_REGION" \
      --global-cluster-identifier "$GLOBAL_ID" --target-db-cluster-identifier "$SECONDARY_ARN" \
      --allow-data-loss >/dev/null
    scale_standby
    wait_writer
    log "Recovered in $(( $(date +%s) - START ))s"
    ;;
  *)
    sed -n '2,13p' "$0"
    exit 1
    ;;
esac
