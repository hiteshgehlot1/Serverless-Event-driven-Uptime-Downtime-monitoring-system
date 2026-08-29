terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "alert_email" {
  type        = string
  description = "Email address to receive immediate website downtime alerts"
}

# 1. DynamoDB Table for Health Metrics
resource "aws_dynamodb_table" "uptime_logs" {
  name         = "UptimeMetrics"
  billing_mode = "PAY_PER_REQUEST" # Always Free tier compliant
  hash_key     = "site_url"
  range_key    = "timestamp"

  attribute {
    name = "site_url"
    type = "S"
  }

  attribute {
    name = "timestamp"
    type = "S"
  }

  tags = {
    Project     = "UptimeMonitor"
    Environment = "Dev"
  }
}

# 2. SNS Topic for Email Alerts
resource "aws_sns_topic" "downtime_alerts" {
  name = "uptime-downtime-alerts"
}

resource "aws_sns_topic_subscription" "email_subscription" {
  topic_arn = aws_sns_topic.downtime_alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# 3. IAM Execution Role for Lambda Function
resource "aws_iam_role" "lambda_exec_role" {
  name = "uptime_monitor_lambda_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })
}

# IAM Policy: Least-Privilege permissions for DynamoDB, SNS, and CloudWatch
resource "aws_iam_policy" "lambda_policy" {
  name        = "uptime_monitor_lambda_policy"
  description = "Allows Lambda to log metrics, publish to SNS, and write to DynamoDB"

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
        Resource = "arn:aws:logs:*:*:*"
      },
      {
        Effect = "Allow"
        Action = [
          "dynamodb:PutItem",
          "dynamodb:Query",
          "dynamodb:Scan"
        ]
        Resource = aws_dynamodb_table.uptime_logs.arn
      },
      {
        Effect = "Allow"
        Action = [
          "sns:Publish"
        ]
        Resource = aws_sns_topic.downtime_alerts.arn
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "attach_lambda_policy" {
  role       = aws_iam_role.lambda_exec_role.name
  policy_arn = aws_iam_policy.lambda_policy.arn
}

# 4. EventBridge Rule (Cron schedule every 5 minutes)
resource "aws_cloudwatch_event_rule" "every_five_minutes" {
  name                = "uptime-check-schedule"
  description         = "Triggers health check Lambda every 5 minutes"
  schedule_expression = "rate(5 minutes)"
}

# Terraform Outputs
output "dynamodb_table_name" {
  value = aws_dynamodb_table.uptime_logs.name
}

output "sns_topic_arn" {
  value = aws_sns_topic.downtime_alerts.arn
}

output "lambda_role_arn" {
  value = aws_iam_role.lambda_exec_role.arn
}