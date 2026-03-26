# =============================================================================
#  All configurable variables for the demo environment
#  Fill values in terraform.tfvars (copy from terraform.tfvars.example)
# =============================================================================

# ── Project Identity ─────────────────────────────────────────────────────────
variable "project_name" {
  description = "Project name used in resource naming"
  type        = string
  default     = "rhoai-demo"
}

variable "environment" {
  description = "Environment label: demo | staging | prod"
  type        = string
  default     = "demo"
}

variable "owner_tag" {
  description = "Owner name/email for resource tags"
  type        = string
}

variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "us-east-1"
}

variable "aws_profile" {
  description = "AWS CLI profile for authentication"
  type        = string
  default     = "rhoai-demo"
}

# ── Network ──────────────────────────────────────────────────────────────────
variable "vpc_cidr" {
  description = "VPC CIDR block (/16 required for OCP)"
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  description = "AZs for subnet deployment"
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
}

variable "public_subnet_cidrs" {
  description = "Public subnet CIDRs"
  type        = list(string)
  default     = ["10.0.101.0/24", "10.0.102.0/24"]
}

variable "private_subnet_cidrs" {
  description = "Private subnet CIDRs"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

# ── OCP Cluster ──────────────────────────────────────────────────────────────
variable "cluster_name" {
  description = "OCP cluster name (different from existing ROSA cluster to avoid tag conflicts)"
  type        = string
  default     = "ai-demo"
}

variable "base_domain" {
  description = "Base DNS domain (must have Route53 hosted zone). Cluster at <cluster_name>.<base_domain>"
  type        = string
  default     = "iisdemolab.click"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]+[a-z0-9]$", var.base_domain))
    error_message = "Must be a valid domain name."
  }
}

variable "ocp_version" {
  description = "OpenShift version (4.20.x stable)"
  type        = string
  default     = "4.21.6"
}

variable "master_instance_type" {
  description = "EC2 type for control plane nodes"
  type        = string
  default     = "m5.xlarge"
}

variable "master_count" {
  description = "Number of control plane nodes"
  type        = number
  default     = 3
}

variable "initial_worker_instance_type" {
  description = "EC2 type for initial IPI worker nodes"
  type        = string
  default     = "m5.xlarge"
}

variable "initial_worker_count" {
  description = "Number of initial worker nodes from IPI"
  type        = number
  default     = 2
}

# ── Compute MachineSets ──────────────────────────────────────────────────────
variable "compute_instance_type" {
  description = "EC2 type for compute workers"
  type        = string
  default     = "c5.2xlarge"
}

variable "compute_min_replicas" {
  description = "Min compute workers per AZ"
  type        = number
  default     = 1
}

variable "compute_max_replicas" {
  description = "Max compute workers per AZ"
  type        = number
  default     = 4
}

variable "gpu_instance_type" {
  description = "EC2 type for GPU workers (T4)"
  type        = string
  default     = "g4dn.xlarge"
}

variable "gpu_max_replicas" {
  description = "Max GPU nodes"
  type        = number
  default     = 1
}

# ── Aurora ───────────────────────────────────────────────────────────────────
variable "db_name" {
  description = "Initial database name"
  type        = string
  default     = "rhoai_demo"
}

variable "db_master_username" {
  description = "Master DB username"
  type        = string
  default     = "rhoai_admin"
}

variable "db_master_password" {
  description = "Master DB password"
  type        = string
  sensitive   = true
  default     = "@Demo123#"
}

variable "aurora_engine_version" {
  description = "Aurora PostgreSQL engine version"
  type        = string
  default     = "16.4"
}

variable "aurora_min_acu" {
  description = "Min ACU (0.5 = cheapest idle)"
  type        = number
  default     = 0.5
}

variable "aurora_max_acu" {
  description = "Max ACU"
  type        = number
  default     = 4
}

variable "aurora_skip_snapshot" {
  description = "Skip final snapshot on destroy"
  type        = bool
  default     = true
}

variable "aurora_deletion_protection" {
  description = "Enable deletion protection"
  type        = bool
  default     = false
}

variable "aurora_backup_retention" {
  description = "Backup retention days"
  type        = number
  default     = 1
}

# ── S3 ───────────────────────────────────────────────────────────────────────
variable "pipeline_log_retention_days" {
  description = "Days to keep pipeline logs"
  type        = number
  default     = 30
}

# ── ECR ──────────────────────────────────────────────────────────────────────
variable "ecr_repository_names" {
  description = "ECR repository names (prefixed to avoid conflict with existing ROSA stack)"
  type        = list(string)
  default = [
    "ai-demo/notebook-base",
    "ai-demo/langchain-server",
    "ai-demo/lambda-metering"
  ]
}

variable "ecr_image_tag_mutability" {
  type    = string
  default = "MUTABLE"
}

variable "ecr_scan_on_push" {
  type    = bool
  default = true
}

# ── IAM / IRSA ───────────────────────────────────────────────────────────────
variable "oidc_issuer_url" {
  description = "OIDC issuer URL from OCP cluster (set after cluster install)"
  type        = string
  default     = ""
}

variable "enable_bedrock_access" {
  description = "Create Bedrock access IAM role"
  type        = bool
  default     = true
}

# ── Lambda + Automation ──────────────────────────────────────────────────────
variable "budget_alert_email" {
  description = "Email for budget alerts"
  type        = string
  default     = ""
}

variable "monthly_budget_usd" {
  description = "Monthly budget threshold"
  type        = number
  default     = 700
}

variable "demo_start_cron" {
  description = "Cron for scaling workers UP (UTC)"
  type        = string
  default     = "cron(0 8 ? * MON-FRI *)"
}

variable "demo_stop_cron" {
  description = "Cron for scaling workers DOWN (UTC)"
  type        = string
  default     = "cron(0 20 ? * MON-FRI *)"
}

# ── Auth ─────────────────────────────────────────────────────────────────────
variable "pull_secret" {
  description = "Red Hat pull secret JSON"
  type        = string
  sensitive   = true
  default     = ""
}

variable "ssh_public_key" {
  description = "SSH public key for node access"
  type        = string
  default     = ""
}

variable "admin_password" {
  description = "Default password for admin/developer users"
  type        = string
  sensitive   = true
  default     = "@Demo123#"
}
