variable "bucket_prefix" {
  description = "Prefix for S3 bucket name"
  type        = string
}

variable "pipeline_log_retention_days" {
  description = "Days to keep pipeline logs before expiry"
  type        = number
  default     = 30
}

variable "force_destroy" {
  description = "Force destroy bucket on terraform destroy (true for demo)"
  type        = bool
  default     = true
}

variable "tags" {
  description = "Common tags"
  type        = map(string)
  default     = {}
}
