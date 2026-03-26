output "scheduler_lambda_arn" {
  description = "Lambda scheduler function ARN"
  value       = aws_lambda_function.scheduler.arn
}

output "sns_topic_arn" {
  description = "SNS alerts topic ARN"
  value       = aws_sns_topic.alerts.arn
}

output "budget_name" {
  description = "AWS Budget name"
  value       = aws_budgets_budget.monthly.name
}
