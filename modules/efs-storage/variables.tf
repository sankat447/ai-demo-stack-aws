variable "name" {
  description = "Name prefix for EFS resources"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID"
  type        = string
}

variable "subnet_ids" {
  description = "Subnet IDs for mount targets"
  type        = list(string)
}

variable "security_group_ids" {
  description = "Security group IDs for EFS"
  type        = list(string)
}

variable "ssm_path_prefix" {
  description = "SSM parameter path prefix"
  type        = string
}

variable "tags" {
  description = "Common tags"
  type        = map(string)
  default     = {}
}
