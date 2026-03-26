# =============================================================================
#  Lambda Scheduler + Budget Alerts
#  Scale workers up at 08:00 UTC, down at 20:00 UTC weekdays
#  Budget alert at $700/month via SNS
# =============================================================================

# ── IAM Role for Lambda ─────────────────────────────────────────────────────
resource "aws_iam_role" "scheduler" {
  name = "${var.name}-scheduler-lambda"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "scheduler" {
  name = "${var.name}-scheduler-policy"
  role = aws_iam_role.scheduler.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = ["arn:aws:logs:*:*:*"]
      },
      {
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:GetParameters"
        ]
        Resource = ["*"]
      },
      {
        Effect = "Allow"
        Action = [
          "autoscaling:UpdateAutoScalingGroup",
          "autoscaling:DescribeAutoScalingGroups",
          "ec2:DescribeInstances",
          "ec2:StartInstances",
          "ec2:StopInstances"
        ]
        Resource = ["*"]
      },
      {
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = [aws_sns_topic.alerts.arn]
      }
    ]
  })
}

# ── Lambda Function ─────────────────────────────────────────────────────────
data "archive_file" "scheduler" {
  type        = "zip"
  output_path = "${path.module}/scheduler.zip"

  source {
    content = <<-PYTHON
import json
import boto3
import os

def handler(event, context):
    """Scale OCP worker ASGs up or down based on the event action."""
    action = event.get('action', 'status')
    cluster_name = os.environ.get('CLUSTER_NAME', 'rhoai-demo')
    asg_client = boto3.client('autoscaling')

    # Find ASGs tagged with the cluster name
    paginator = asg_client.get_paginator('describe_auto_scaling_groups')
    target_asgs = []

    for page in paginator.paginate():
        for asg in page['AutoScalingGroups']:
            tags = {t['Key']: t['Value'] for t in asg.get('Tags', [])}
            if tags.get('kubernetes.io/cluster/' + cluster_name) in ['owned', 'shared']:
                if 'gpu' not in asg['AutoScalingGroupName'].lower():
                    target_asgs.append(asg['AutoScalingGroupName'])

    results = []
    for asg_name in target_asgs:
        if action == 'start':
            asg_client.update_auto_scaling_group(
                AutoScalingGroupName=asg_name,
                MinSize=2, DesiredCapacity=2
            )
            results.append(f"Scaled UP {asg_name}")
        elif action == 'stop':
            asg_client.update_auto_scaling_group(
                AutoScalingGroupName=asg_name,
                MinSize=0, DesiredCapacity=0
            )
            results.append(f"Scaled DOWN {asg_name}")
        else:
            results.append(f"Status: {asg_name}")

    return {'statusCode': 200, 'body': json.dumps(results)}
PYTHON
    filename = "index.py"
  }
}

resource "aws_lambda_function" "scheduler" {
  filename         = data.archive_file.scheduler.output_path
  source_code_hash = data.archive_file.scheduler.output_base64sha256
  function_name    = "${var.name}-ocp-scheduler"
  role             = aws_iam_role.scheduler.arn
  handler          = "index.handler"
  runtime          = "python3.12"
  timeout          = 60

  environment {
    variables = {
      CLUSTER_NAME = var.cluster_name
    }
  }

  tags = var.tags
}

# ── EventBridge Rules ───────────────────────────────────────────────────────
resource "aws_cloudwatch_event_rule" "start" {
  name                = "${var.name}-ocp-start"
  description         = "Scale up OCP workers weekday mornings"
  schedule_expression = var.start_schedule_cron

  tags = var.tags
}

resource "aws_cloudwatch_event_target" "start" {
  rule  = aws_cloudwatch_event_rule.start.name
  arn   = aws_lambda_function.scheduler.arn
  input = jsonencode({ action = "start" })
}

resource "aws_lambda_permission" "start" {
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.scheduler.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.start.arn
}

resource "aws_cloudwatch_event_rule" "stop" {
  name                = "${var.name}-ocp-stop"
  description         = "Scale down OCP workers weekday evenings"
  schedule_expression = var.stop_schedule_cron

  tags = var.tags
}

resource "aws_cloudwatch_event_target" "stop" {
  rule  = aws_cloudwatch_event_rule.stop.name
  arn   = aws_lambda_function.scheduler.arn
  input = jsonencode({ action = "stop" })
}

resource "aws_lambda_permission" "stop" {
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.scheduler.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.stop.arn
}

# ── SNS Topic for Alerts ───────────────────────────────────────────────────
resource "aws_sns_topic" "alerts" {
  name = "${var.name}-alerts"
  tags = var.tags
}

resource "aws_sns_topic_subscription" "email" {
  count     = var.alert_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# ── Budget Alert ────────────────────────────────────────────────────────────
resource "aws_budgets_budget" "monthly" {
  name         = "${var.name}-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_sns_topic_arns  = [aws_sns_topic.alerts.arn]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_sns_topic_arns  = [aws_sns_topic.alerts.arn]
  }
}
