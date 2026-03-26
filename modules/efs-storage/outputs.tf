output "file_system_id" {
  description = "EFS file system ID"
  value       = aws_efs_file_system.main.id
}

output "file_system_dns" {
  description = "EFS DNS name"
  value       = aws_efs_file_system.main.dns_name
}

output "access_point_id" {
  description = "EFS access point ID for RHOAI notebooks"
  value       = aws_efs_access_point.rhoai_notebooks.id
}
