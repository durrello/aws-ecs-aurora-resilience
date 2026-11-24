output "cluster_identifier" {
  value = aws_rds_cluster.this.cluster_identifier
}

output "cluster_arn" {
  value = aws_rds_cluster.this.arn
}

output "writer_endpoint" {
  value = aws_rds_cluster.this.endpoint
}

output "reader_endpoint" {
  value = aws_rds_cluster.this.reader_endpoint
}

output "security_group_id" {
  value = aws_security_group.this.id
}

output "subnet_group_name" {
  value = aws_db_subnet_group.this.name
}

# The instances must exist before a secondary cluster can join the global database.
output "instance_ids" {
  value = aws_rds_cluster_instance.this[*].id
}
