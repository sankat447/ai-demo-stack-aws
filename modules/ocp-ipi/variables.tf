variable "cluster_name" {
  description = "OCP cluster name"
  type        = string
}

variable "base_domain" {
  description = "Base DNS domain for the cluster (e.g., example.com)"
  type        = string
}

variable "ocp_version" {
  description = "OpenShift version (e.g., 4.20.17)"
  type        = string
  default     = "4.21.6"
}

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "aws_profile" {
  description = "AWS profile for authentication"
  type        = string
  default     = "rhoai-demo"
}

variable "aws_access_key_id" {
  description = "Static AWS access key ID for openshift-install (SSO tokens not supported)"
  type        = string
  default     = ""
  sensitive   = true
}

variable "aws_secret_access_key" {
  description = "Static AWS secret access key for openshift-install"
  type        = string
  default     = ""
  sensitive   = true
}

variable "master_instance_type" {
  description = "EC2 instance type for control plane nodes"
  type        = string
  default     = "m5.xlarge"
}

variable "master_count" {
  description = "Number of control plane nodes"
  type        = number
  default     = 3
}

variable "worker_instance_type" {
  description = "EC2 instance type for initial worker nodes"
  type        = string
  default     = "m5.xlarge"
}

variable "worker_count" {
  description = "Number of initial worker nodes"
  type        = number
  default     = 2
}

variable "vpc_cidr" {
  description = "VPC CIDR block"
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for nodes"
  type        = list(string)
}

variable "public_subnet_ids" {
  description = "Public subnet IDs for load balancers"
  type        = list(string)
}

variable "pull_secret" {
  description = "Red Hat pull secret JSON (from cloud.redhat.com)"
  type        = string
  sensitive   = true
}

variable "ssh_public_key" {
  description = "SSH public key for node access"
  type        = string
  default     = ""
}

variable "admin_password" {
  description = "Password for the admin/developer htpasswd users"
  type        = string
  sensitive   = true
  default     = "@Demo123#"
}

variable "fips_enabled" {
  description = "Enable FIPS mode"
  type        = bool
  default     = false
}

variable "network_type" {
  description = "Cluster network type (OVNKubernetes or OpenShiftSDN)"
  type        = string
  default     = "OVNKubernetes"
}


variable "install_dir" {
  description = "Directory to store install artifacts"
  type        = string
  default     = "./ocp-install-dir"
}

variable "tags" {
  description = "Common tags"
  type        = map(string)
  default     = {}
}
