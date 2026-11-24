output "primary_url" {
  value = "http://${module.app_primary.alb_dns_name}"
}

output "secondary_url" {
  value = "http://${module.app_secondary.alb_dns_name}"
}

output "global_cluster_id" {
  value = aws_rds_global_cluster.this.id
}

output "primary_cluster_id" {
  value = module.aurora_primary.cluster_identifier
}

output "secondary_cluster_id" {
  value = module.aurora_secondary.cluster_identifier
}

output "primary_cluster_arn" {
  value = module.aurora_primary.cluster_arn
}

output "secondary_cluster_arn" {
  value = module.aurora_secondary.cluster_arn
}

# Inputs for scripts/restore-test.sh
output "restore_test_inputs" {
  value = {
    region            = var.primary_region
    cluster_id        = module.aurora_primary.cluster_identifier
    subnet_group      = module.aurora_primary.subnet_group_name
    security_group_id = module.aurora_primary.security_group_id
    secret_arn        = aws_secretsmanager_secret.db.arn
  }
}

output "ecs" {
  value = {
    primary   = { cluster = module.app_primary.cluster_name, service = module.app_primary.service_name }
    secondary = { cluster = module.app_secondary.cluster_name, service = module.app_secondary.service_name }
  }
}
