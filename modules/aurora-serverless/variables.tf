variable "cluster_identifier" {
  description = "Aurora cluster identifier"
  type        = string
}

variable "database_name" {
  description = "Initial database name"
  type        = string
  default     = "rhoai_demo"
}

variable "master_username" {
  description = "Master DB username"
  type        = string
  default     = "rhoai_admin"
}

variable "master_password" {
  description = "Master DB password"
  type        = string
  sensitive   = true
}

variable "engine_version" {
  description = "Aurora PostgreSQL engine version"
  type        = string
  default     = "16.4"
}

variable "min_acu" {
  description = "Minimum Aurora Capacity Units (0.5 = cheapest)"
  type        = number
  default     = 0.5
}

variable "max_acu" {
  description = "Maximum Aurora Capacity Units"
  type        = number
  default     = 4
}

variable "subnet_ids" {
  description = "Subnet IDs for DB subnet group"
  type        = list(string)
}

variable "security_group_ids" {
  description = "Security group IDs for Aurora"
  type        = list(string)
}

variable "ssm_path_prefix" {
  description = "SSM parameter path prefix"
  type        = string
}

variable "skip_final_snapshot" {
  description = "Skip final snapshot on destroy (true for demo)"
  type        = bool
  default     = true
}

variable "deletion_protection" {
  description = "Enable deletion protection (false for demo)"
  type        = bool
  default     = false
}

variable "backup_retention_days" {
  description = "Backup retention period in days"
  type        = number
  default     = 1
}

variable "tags" {
  description = "Common tags"
  type        = map(string)
  default     = {}
}
