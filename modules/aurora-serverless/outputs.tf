output "cluster_endpoint" {
  description = "Aurora cluster endpoint"
  value       = aws_rds_cluster.aurora.endpoint
}

output "cluster_reader_endpoint" {
  description = "Aurora reader endpoint"
  value       = aws_rds_cluster.aurora.reader_endpoint
}

output "database_name" {
  description = "Database name"
  value       = aws_rds_cluster.aurora.database_name
}

output "port" {
  description = "Database port"
  value       = aws_rds_cluster.aurora.port
}

output "cluster_id" {
  description = "Aurora cluster ID"
  value       = aws_rds_cluster.aurora.id
}

output "ssm_endpoint_path" {
  description = "SSM path for DB endpoint"
  value       = aws_ssm_parameter.db_endpoint.name
}

output "ssm_password_path" {
  description = "SSM path for DB password"
  value       = aws_ssm_parameter.db_password.name
}
