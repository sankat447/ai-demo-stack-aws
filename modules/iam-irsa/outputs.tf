output "s3_role_arn" {
  description = "IAM role ARN for S3 access"
  value       = aws_iam_role.s3_access.arn
}

output "bedrock_role_arn" {
  description = "IAM role ARN for Bedrock access"
  value       = var.enable_bedrock_access ? aws_iam_role.bedrock_access[0].arn : ""
}

output "ecr_role_arn" {
  description = "IAM role ARN for ECR access"
  value       = aws_iam_role.ecr_access.arn
}

output "ssm_role_arn" {
  description = "IAM role ARN for SSM access"
  value       = aws_iam_role.ssm_access.arn
}

output "oidc_provider_arn" {
  description = "OIDC provider ARN"
  value       = aws_iam_openid_connect_provider.ocp.arn
}
