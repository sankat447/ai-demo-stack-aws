variable "cluster_name" {
  description = "OCP cluster name"
  type        = string
}

variable "aws_region" {
  description = "AWS region"
  type        = string
}

variable "oidc_issuer_url" {
  description = "OIDC issuer URL for the OCP cluster"
  type        = string
}

variable "oidc_thumbprint" {
  description = "OIDC provider TLS certificate thumbprint"
  type        = string
  default     = "a9d53002e97e00ab26eb159611b4ce7da3d84484"
}

variable "s3_bucket_arn" {
  description = "S3 data lake bucket ARN"
  type        = string
}

variable "enable_bedrock_access" {
  description = "Create Bedrock access role"
  type        = bool
  default     = true
}

variable "ssm_path_prefix" {
  description = "SSM parameter path prefix for access"
  type        = string
}

variable "tags" {
  description = "Common tags"
  type        = map(string)
  default     = {}
}
