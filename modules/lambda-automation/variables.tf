variable "name" {
  description = "Name prefix"
  type        = string
}

variable "cluster_name" {
  description = "OCP cluster name for ASG tagging"
  type        = string
}

variable "start_schedule_cron" {
  description = "Cron expression for scaling up workers (UTC)"
  type        = string
  default     = "cron(0 8 ? * MON-FRI *)"
}

variable "stop_schedule_cron" {
  description = "Cron expression for scaling down workers (UTC)"
  type        = string
  default     = "cron(0 20 ? * MON-FRI *)"
}

variable "alert_email" {
  description = "Email for budget/alert notifications"
  type        = string
  default     = ""
}

variable "monthly_budget_usd" {
  description = "Monthly budget threshold in USD"
  type        = number
  default     = 700
}

variable "tags" {
  description = "Common tags"
  type        = map(string)
  default     = {}
}
