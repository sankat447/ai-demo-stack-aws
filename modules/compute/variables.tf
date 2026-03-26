variable "cluster_name" {
  description = "OCP cluster name"
  type        = string
}

variable "infrastructure_id" {
  description = "OCP infrastructure ID (from metadata.json)"
  type        = string
}

variable "availability_zones" {
  description = "AZs for worker placement"
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
}

variable "compute_instance_type" {
  description = "EC2 type for compute workers"
  type        = string
  default     = "c5.2xlarge"
}

variable "compute_min_replicas" {
  description = "Min compute replicas per AZ"
  type        = number
  default     = 1
}

variable "compute_max_replicas" {
  description = "Max compute replicas per AZ"
  type        = number
  default     = 4
}

variable "gpu_instance_type" {
  description = "EC2 type for GPU workers (T4)"
  type        = string
  default     = "g4dn.xlarge"
}

variable "gpu_max_replicas" {
  description = "Max GPU replicas"
  type        = number
  default     = 1
}

variable "ami_id" {
  description = "RHCOS AMI ID for workers"
  type        = string
  default     = ""
}

variable "kubeconfig_path" {
  description = "Path to kubeconfig"
  type        = string
}

variable "output_dir" {
  description = "Directory to write MachineSet YAMLs"
  type        = string
  default     = "./generated"
}

variable "tags" {
  description = "Common tags"
  type        = map(string)
  default     = {}
}
