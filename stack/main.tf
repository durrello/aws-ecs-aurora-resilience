# Two-region stack:
#   primary   = VPC + ECS Fargate (serving) + Aurora PostgreSQL writer cluster
#   secondary = VPC + ECS Fargate (scaled to zero) + Aurora read-only secondary cluster
# Aurora Global Database replicates storage across regions. Route 53 sends traffic to the
# primary while its health check passes, and to the secondary after a failover.
locals {
  prefix = "${var.name}-${var.environment}"
  tags = {
    Project     = var.name
    Environment = var.environment
    ManagedBy   = "terraform"
  }
  dns = var.hosted_zone_id != "" && var.app_hostname != ""
}

# ---------- Networks ----------
module "network_primary" {
  source = "../modules/network"
  name   = "${local.prefix}-primary"
  cidr   = var.primary_cidr
}

module "network_secondary" {
  source    = "../modules/network"
  providers = { aws = aws.secondary }
  name      = "${local.prefix}-secondary"
  cidr      = var.secondary_cidr
}

# ---------- Database credentials, replicated to the standby region ----------
resource "random_password" "db" {
  length  = 32
  special = false
}

resource "aws_secretsmanager_secret" "db" {
  name                    = "${local.prefix}/aurora"
  recovery_window_in_days = 7

  replica {
    region = var.secondary_region
  }
}

resource "aws_secretsmanager_secret_version" "db" {
  secret_id = aws_secretsmanager_secret.db.id
  secret_string = jsonencode({
    username = "app_admin"
    password = random_password.db.result
  })
}

locals {
  secret_arn_secondary = replace(aws_secretsmanager_secret.db.arn, ":${var.primary_region}:", ":${var.secondary_region}:")
}

# ---------- Aurora Global Database ----------
resource "aws_rds_global_cluster" "this" {
  global_cluster_identifier = local.prefix
  engine                    = "aurora-postgresql"
  engine_version            = var.aurora_engine_version
  database_name             = "app"
  storage_encrypted         = true
  deletion_protection       = var.deletion_protection

  lifecycle {
    ignore_changes = [engine_version]
  }
}

module "aurora_primary" {
  source                     = "../modules/aurora"
  name                       = "${local.prefix}-primary"
  is_primary                 = true
  global_cluster_identifier  = aws_rds_global_cluster.this.id
  engine_version             = var.aurora_engine_version
  parameter_group_major      = var.aurora_parameter_group_major
  master_username            = "app_admin"
  master_password            = random_password.db.result
  vpc_id                     = module.network_primary.vpc_id
  subnet_ids                 = module.network_primary.private_subnet_ids
  allowed_security_group_ids = [module.app_primary.service_security_group_id]
  deletion_protection        = var.deletion_protection
}

module "aurora_secondary" {
  source                     = "../modules/aurora"
  providers                  = { aws = aws.secondary }
  name                       = "${local.prefix}-secondary"
  is_primary                 = false
  global_cluster_identifier  = aws_rds_global_cluster.this.id
  engine_version             = var.aurora_engine_version
  parameter_group_major      = var.aurora_parameter_group_major
  vpc_id                     = module.network_secondary.vpc_id
  subnet_ids                 = module.network_secondary.private_subnet_ids
  allowed_security_group_ids = [module.app_secondary.service_security_group_id]
  instance_count             = 1
  deletion_protection        = var.deletion_protection

  # A secondary cluster can only join once the primary has a writer instance.
  depends_on = [module.aurora_primary]
}

# ---------- Application on ECS Fargate ----------
module "app_primary" {
  source             = "../modules/ecs-service"
  name               = "${local.prefix}-primary"
  vpc_id             = module.network_primary.vpc_id
  vpc_cidr           = var.primary_cidr
  public_subnet_ids  = module.network_primary.public_subnet_ids
  private_subnet_ids = module.network_primary.private_subnet_ids
  container_image    = var.container_image_primary
  db_host            = module.aurora_primary.writer_endpoint
  db_name            = "app"
  db_secret_arn      = aws_secretsmanager_secret.db.arn
}

module "app_secondary" {
  source             = "../modules/ecs-service"
  providers          = { aws = aws.secondary }
  name               = "${local.prefix}-secondary"
  vpc_id             = module.network_secondary.vpc_id
  vpc_cidr           = var.secondary_cidr
  public_subnet_ids  = module.network_secondary.public_subnet_ids
  private_subnet_ids = module.network_secondary.private_subnet_ids
  container_image    = var.container_image_secondary
  # The secondary cluster endpoint becomes writable after a global failover or switchover.
  db_host       = module.aurora_secondary.writer_endpoint
  db_name       = "app"
  db_secret_arn = local.secret_arn_secondary
  desired_count = var.standby_desired_count
  min_count     = var.standby_desired_count
}

# ---------- DNS failover (optional) ----------
resource "aws_route53_health_check" "primary" {
  count             = local.dns ? 1 : 0
  fqdn              = module.app_primary.alb_dns_name
  type              = "HTTP"
  port              = 80
  resource_path     = "/health"
  failure_threshold = 3
  request_interval  = 10
}

resource "aws_route53_record" "primary" {
  count           = local.dns ? 1 : 0
  zone_id         = var.hosted_zone_id
  name            = var.app_hostname
  type            = "A"
  set_identifier  = "primary"
  health_check_id = aws_route53_health_check.primary[0].id

  failover_routing_policy {
    type = "PRIMARY"
  }

  alias {
    name                   = module.app_primary.alb_dns_name
    zone_id                = module.app_primary.alb_zone_id
    evaluate_target_health = true
  }
}

resource "aws_route53_record" "secondary" {
  count          = local.dns ? 1 : 0
  zone_id        = var.hosted_zone_id
  name           = var.app_hostname
  type           = "A"
  set_identifier = "secondary"

  failover_routing_policy {
    type = "SECONDARY"
  }

  alias {
    name                   = module.app_secondary.alb_dns_name
    zone_id                = module.app_secondary.alb_zone_id
    evaluate_target_health = true
  }
}
