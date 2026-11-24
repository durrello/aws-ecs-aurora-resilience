# Aurora PostgreSQL cluster (Serverless v2 instances).
# The same module builds the primary cluster and, when global_cluster_identifier is set and
# is_primary is false, a read-only secondary cluster in another region.
data "aws_region" "this" {}

resource "aws_kms_key" "this" {
  description             = "Aurora storage encryption for ${var.name} in ${data.aws_region.this.region}"
  enable_key_rotation     = true
  deletion_window_in_days = 7
}

resource "aws_db_subnet_group" "this" {
  name       = var.name
  subnet_ids = var.subnet_ids
}

resource "aws_security_group" "this" {
  name        = "${var.name}-db"
  description = "PostgreSQL from the application only"
  vpc_id      = var.vpc_id

  ingress {
    description     = "PostgreSQL from the ECS service"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = var.allowed_security_group_ids
  }
}

resource "aws_rds_cluster_parameter_group" "this" {
  name        = "${var.name}-pg${var.parameter_group_major}"
  family      = "aurora-postgresql${var.parameter_group_major}"
  description = "Force TLS, log slow statements, allow blue/green"

  parameter {
    name  = "rds.force_ssl"
    value = "1"
  }

  parameter {
    name  = "log_min_duration_statement"
    value = "1000"
  }

  # Required by RDS Blue/Green Deployments for Aurora PostgreSQL (green is kept in sync by
  # logical replication). Static parameter: takes effect after the writer reboots.
  parameter {
    name         = "rds.logical_replication"
    value        = "1"
    apply_method = "pending-reboot"
  }
}

resource "aws_rds_cluster" "this" {
  cluster_identifier              = var.name
  engine                          = "aurora-postgresql"
  engine_mode                     = "provisioned"
  engine_version                  = var.engine_version
  global_cluster_identifier       = var.global_cluster_identifier
  database_name                   = var.is_primary ? var.database_name : null
  master_username                 = var.is_primary ? var.master_username : null
  master_password                 = var.is_primary ? var.master_password : null
  db_subnet_group_name            = aws_db_subnet_group.this.name
  vpc_security_group_ids          = [aws_security_group.this.id]
  db_cluster_parameter_group_name = aws_rds_cluster_parameter_group.this.name
  storage_encrypted               = true
  kms_key_id                      = aws_kms_key.this.arn

  # Backups: automated backups with point-in-time restore inside the retention window.
  # scripts/restore-test.sh proves these backups by restoring them on a schedule.
  backup_retention_period      = var.backup_retention_days
  preferred_backup_window      = "02:00-03:00"
  preferred_maintenance_window = "sun:03:30-sun:04:30"
  copy_tags_to_snapshot        = true

  deletion_protection                 = var.deletion_protection
  skip_final_snapshot                 = !var.deletion_protection
  final_snapshot_identifier           = var.deletion_protection ? "${var.name}-final" : null
  iam_database_authentication_enabled = true
  enabled_cloudwatch_logs_exports     = ["postgresql"]

  serverlessv2_scaling_configuration {
    min_capacity = var.min_acu
    max_capacity = var.max_acu
  }

  # After a global switchover the roles of the two clusters swap; Terraform should not try
  # to undo that, and engine upgrades are run by the upgrade scripts, not by apply.
  lifecycle {
    ignore_changes = [replication_source_identifier, global_cluster_identifier, engine_version]
  }
}

resource "aws_rds_cluster_instance" "this" {
  count                        = var.instance_count
  identifier                   = "${var.name}-${count.index + 1}"
  cluster_identifier           = aws_rds_cluster.this.id
  engine                       = aws_rds_cluster.this.engine
  instance_class               = "db.serverless"
  db_subnet_group_name         = aws_db_subnet_group.this.name
  auto_minor_version_upgrade   = true
  performance_insights_enabled = true
  copy_tags_to_snapshot        = true

  lifecycle {
    ignore_changes = [engine_version]
  }
}
