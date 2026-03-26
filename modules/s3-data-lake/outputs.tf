output "bucket_name" {
  description = "S3 data lake bucket name"
  value       = aws_s3_bucket.data_lake.id
}

output "bucket_arn" {
  description = "S3 data lake bucket ARN"
  value       = aws_s3_bucket.data_lake.arn
}

output "bucket_domain_name" {
  description = "S3 bucket domain name"
  value       = aws_s3_bucket.data_lake.bucket_domain_name
}
