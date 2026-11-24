# aws-ecs-aurora-resilience

A two-region AWS platform in Terraform: a containerised service on **ECS Fargate** backed by
**Aurora PostgreSQL** in an **Aurora Global Database**, with scripts for the three operations
that usually live only in a runbook:

1. **Zero-downtime database upgrades** with RDS Blue/Green Deployments (whole global database).
2. **Tested restores**: a point-in-time restore into a throwaway cluster, checked and timed.
3. **Regional failover drills**: planned switchover and unplanned failover to the second region.

## Architecture

```
                       Route 53 failover record (optional)
                     PRIMARY (health checked)   SECONDARY
                            |                       |
eu-west-1 (primary)         v                       v           eu-west-2 (standby)
+-----------------------------------+     +-----------------------------------+
| ALB (public subnets)              |     | ALB (public subnets)              |
|   -> ECS Fargate service          |     |   -> ECS Fargate service          |
|      private subnets, 2+ tasks    |     |      private subnets, 0 tasks     |
|      circuit-breaker rollback     |     |      (pilot light, scaled up      |
|      CPU target-tracking scaling  |     |       by the failover drill)      |
|   -> Aurora PostgreSQL writer     | ==> |   -> Aurora secondary cluster     |
|      Serverless v2, 2 instances   |     |      read-only, 1 instance        |
|      KMS, TLS forced, 7-day PITR  |     |      storage-level replication    |
+-----------------------------------+     +-----------------------------------+
         Secrets Manager secret replicated to both regions
```

## What is in the repo

| Path | Contents |
|---|---|
| `modules/network` | VPC, public and private subnets across 2 or 3 AZs, NAT, VPC flow logs, locked-down default security group |
| `modules/ecs-service` | ECS cluster with Container Insights, Fargate task and service, ALB with optional HTTPS (TLS 1.3 policy), deployment circuit breaker with automatic rollback, CPU target-tracking autoscaling, least-privilege IAM |
| `modules/aurora` | Aurora PostgreSQL cluster (Serverless v2), KMS encryption, forced TLS, logical replication enabled for blue/green, automated backups, Performance Insights, works as a global primary or secondary |
| `stack` | Wires both regions together: global database, replicated secret, two services, optional Route 53 failover |
| `app` | A small Python service: `/health` for load balancers, `/` reports the serving region and whether the database is the writer or read-only |
| `scripts/blue-green-upgrade.sh` | Create, check, switch and clean up an RDS Blue/Green Deployment of the global database |
| `scripts/restore-test.sh` | Point-in-time restore, in-VPC check as a one-off ECS task, timing, cleanup, result appended to `restore-test-results.jsonl` |
| `scripts/failover-drill.sh` | `switchover` (planned, no data loss), `failover` (unplanned, with confirmation), `status` |

## Design decisions

- **Pilot light standby.** The secondary region runs the full network, load balancer and
  database, but zero tasks. The failover drill scales it up. Set `standby_desired_count = 2`
  for warm standby if the recovery-time target needs it.
- **Terraform does not fight operations.** The Aurora modules ignore `engine_version` and the
  global-cluster membership attributes, because blue/green switchovers and global failovers
  change them outside Terraform. After an upgrade, update the version variables so code and
  reality match again. The ECS service ignores `desired_count` so autoscaling and the drill
  own it.
- **Safe deploys.** New task definitions roll out at 100% minimum healthy; if the new tasks fail
  the `/health` check, the ECS circuit breaker rolls back to the last working version.
- **Least privilege.** The task execution role can read one secret. The task role has no
  permissions. Aurora accepts connections only from the service security group, and only over
  TLS.
- **Blue/green on a global database.** RDS Blue/Green Deployments support Aurora Global
  Database: the green copy spans both regions and the switchover renames endpoints, so the app
  needs no change. Aurora PostgreSQL blue/green needs `rds.logical_replication = 1`, which this
  module sets. See the
  [AWS documentation](https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/aurora-global-database-bluegreen.html).

## Usage

```bash
# 1. Build and push the image to ECR in both regions (or use ECR cross-region replication)
docker build -t ecs-aurora-app app

# 2. Configure
cd stack
cp terraform.tfvars.example terraform.tfvars   # set the two image URIs
terraform init
terraform plan
terraform apply

# 3. Operations (from the repo root)
scripts/restore-test.sh 15                      # restore to 15 minutes ago, check, delete
scripts/blue-green-upgrade.sh create 17.4 <pg17-cluster-parameter-group>
scripts/blue-green-upgrade.sh switch
scripts/failover-drill.sh switchover            # planned region move
scripts/failover-drill.sh status

# 4. Tear down
terraform destroy
```

## Verification status

| Check | Where | Result |
|---|---|---|
| `terraform fmt` and `terraform validate` | CI and local | Passing |
| `terraform plan` against a real AWS account | Local | 87 resources, no errors |
| Trivy IaC scan, HIGH and CRITICAL | CI and local | Passing; accepted findings listed in `.trivyignore` with reasons |
| shellcheck on all scripts | CI and local | Passing |
| Image build and `/health` smoke test | CI | See the Actions tab |
| Full apply, restore test, blue/green and failover drill | Not yet run in this repo | Results will be recorded in this table when run |

## Cost

This stack runs billable resources in two regions: NAT gateways, load balancers, Aurora
Serverless v2 capacity and storage, cross-region replication, Fargate tasks and Route 53 health
checks. Price it for your regions with the
[AWS Pricing Calculator](https://calculator.aws/) before applying, and run `terraform destroy`
when you are done.

## License

MIT
