variable "name" {
  description = "Name prefix"
  type        = string
}

variable "base_domain" {
  description = "Base domain for the cluster"
  type        = string
}

variable "tags" {
  description = "Common tags"
  type        = map(string)
  default     = {}
}
