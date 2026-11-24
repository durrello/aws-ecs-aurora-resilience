#!/usr/bin/env bash
# Prove the backups work: restore the primary Aurora cluster to a point in time into a
# throwaway cluster, run SQL checks against it, record the result, then delete it.
#
# Usage: scripts/restore-test.sh [minutes-ago]   (default 15)
#
# Exit code 0 only if the restore completed AND the checks passed. The timing (how long
# the restore took) is your measured recovery time for this database size.
set -euo pipefail

MINUTES_AGO="${1:-15}"
cd "$(dirname "$0")/../stack"
IN=$(terraform output -json restore_test_inputs)
REGION=$(jq -r .region <<<"$IN")
SOURCE=$(jq -r .cluster_id <<<"$IN")
SUBNETS=$(jq -r .subnet_group <<<"$IN")
SG=$(jq -r .security_group_id <<<"$IN")

STAMP=$(date -u +%Y%m%d%H%M%S)
TARGET="${SOURCE}-restore-test-${STAMP}"
RESTORE_TIME=$(date -u -v-"${MINUTES_AGO}"M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
  || date -u -d "${MINUTES_AGO} minutes ago" +%Y-%m-%dT%H:%M:%SZ)

cleanup() {
  echo "Deleting ${TARGET}"
  aws rds delete-db-instance --region "$REGION" --db-instance-identifier "${TARGET}-1" \
    --skip-final-snapshot >/dev/null 2>&1 || true
  aws rds wait db-instance-deleted --region "$REGION" --db-instance-identifier "${TARGET}-1" 2>/dev/null || true
  aws rds delete-db-cluster --region "$REGION" --db-cluster-identifier "$TARGET" \
    --skip-final-snapshot >/dev/null 2>&1 || true
}
trap cleanup EXIT

START=$(date +%s)
echo "Restoring ${SOURCE} to ${RESTORE_TIME} as ${TARGET}"
aws rds restore-db-cluster-to-point-in-time --region "$REGION" \
  --source-db-cluster-identifier "$SOURCE" \
  --db-cluster-identifier "$TARGET" \
  --restore-to-time "$RESTORE_TIME" \
  --db-subnet-group-name "$SUBNETS" \
  --vpc-security-group-ids "$SG" \
  --serverless-v2-scaling-configuration MinCapacity=0.5,MaxCapacity=2 \
  --tags Key=Purpose,Value=restore-test >/dev/null

aws rds create-db-instance --region "$REGION" \
  --db-instance-identifier "${TARGET}-1" \
  --db-cluster-identifier "$TARGET" \
  --db-instance-class db.serverless \
  --engine aurora-postgresql >/dev/null

aws rds wait db-instance-available --region "$REGION" --db-instance-identifier "${TARGET}-1"
RESTORE_SECONDS=$(( $(date +%s) - START ))
ENDPOINT=$(aws rds describe-db-clusters --region "$REGION" --db-cluster-identifier "$TARGET" \
  --query 'DBClusters[0].Endpoint' --output text)
echo "Restore available after ${RESTORE_SECONDS}s at ${ENDPOINT}"

# The checks run inside the VPC (the restored cluster is private), as a one-off ECS task
# using the same image, so no database port is ever opened to the internet.
ECS=$(terraform output -json ecs | jq -r .primary.cluster)
SERVICE=$(terraform output -json ecs | jq -r .primary.service)
NETCFG=$(aws ecs describe-services --region "$REGION" --cluster "$ECS" --services "$SERVICE" \
  --query 'services[0].networkConfiguration' --output json)
TASKDEF=$(aws ecs describe-services --region "$REGION" --cluster "$ECS" --services "$SERVICE" \
  --query 'services[0].taskDefinition' --output text)

# Check: the restored cluster accepts a TLS login with the app credentials and is a writable
# database. For a real workload, extend this with row counts of your key tables compared
# against the source at the restore time.
CHECK_SQL="SELECT CASE WHEN NOT pg_is_in_recovery() THEN 'ok' ELSE 'read-only' END"
OVERRIDES=$(jq -n --arg host "$ENDPOINT" --arg sql "$CHECK_SQL" '{
  containerOverrides: [{
    name: "app",
    environment: [{name: "DB_HOST", value: $host}],
    command: ["python", "-c", ("import os,psycopg; c=psycopg.connect(host=os.environ[\"DB_HOST\"],dbname=os.environ.get(\"DB_NAME\",\"app\"),user=os.environ[\"DB_USER\"],password=os.environ[\"DB_PASSWORD\"],sslmode=\"require\"); r=c.execute(\"" + $sql + "\").fetchone()[0]; print(\"restore-check:\", r); raise SystemExit(0 if r == \"ok\" else 1)")]
  }]
}')

TASK=$(aws ecs run-task --region "$REGION" --cluster "$ECS" --launch-type FARGATE \
  --task-definition "$TASKDEF" --network-configuration "$NETCFG" \
  --overrides "$OVERRIDES" --query 'tasks[0].taskArn' --output text)
aws ecs wait tasks-stopped --region "$REGION" --cluster "$ECS" --tasks "$TASK"
EXIT_CODE=$(aws ecs describe-tasks --region "$REGION" --cluster "$ECS" --tasks "$TASK" \
  --query 'tasks[0].containers[0].exitCode' --output text)

RESULT=$([[ "$EXIT_CODE" == "0" ]] && echo PASS || echo FAIL)
echo "{\"date\":\"$(date -u +%FT%TZ)\",\"source\":\"${SOURCE}\",\"restore_to\":\"${RESTORE_TIME}\",\"restore_seconds\":${RESTORE_SECONDS},\"check\":\"${RESULT}\"}" \
  | tee -a ../restore-test-results.jsonl
[[ "$RESULT" == "PASS" ]]
