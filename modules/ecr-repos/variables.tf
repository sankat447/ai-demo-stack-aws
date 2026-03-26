variable "repository_names" {
  description = "List of ECR repository names"
  type        = list(string)
  default = [
    "rhoai-demo/notebook-base",
    "rhoai-demo/langchain-server",
    "rhoai-demo/lambda-metering"
  ]
}

variable "image_tag_mutability" {
  description = "Image tag mutability setting"
  type        = string
  default     = "MUTABLE"
}

variable "scan_on_push" {
  description = "Enable image scanning on push"
  type        = bool
  default     = true
}

variable "tags" {
  description = "Common tags"
  type        = map(string)
  default     = {}
}
