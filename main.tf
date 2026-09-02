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


# Package Python code into a ZIP archive automatically
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "${path.module}/src/lambda_function.py"
  output_path = "${path.module}/lambda_function.zip"
}

# AWS Lambda Function
resource "aws_lambda_function" "uptime_checker" {
  filename         = data.archive_file.lambda_zip.output_path
  function_name    = "uptime-monitor-checker"
  role             = aws_iam_role.lambda_exec_role.arn
  handler          = "lambda_function.lambda_handler"
  runtime          = "python3.11"
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256

  environment {
    variables = {
      DYNAMODB_TABLE = aws_dynamodb_table.uptime_logs.name
      SNS_TOPIC_ARN  = aws_sns_topic.downtime_alerts.arn
    }
  }
}

# Public Lambda Function URL (CORS Enabled)
resource "aws_lambda_function_url" "lambda_public_url" {
  function_name      = aws_lambda_function.uptime_checker.function_name
  authorization_type = "NONE"

  cors {
    allow_credentials = false
    allow_origins     = ["*"]
    allow_methods     = ["GET"]
  }
}

# Link EventBridge Trigger to Lambda Function
resource "aws_cloudwatch_event_target" "trigger_lambda_on_schedule" {
  rule      = aws_cloudwatch_event_rule.every_five_minutes.name
  target_id = "UptimeLambdaTarget"
  arn       = aws_lambda_function.uptime_checker.arn
}

# Grant EventBridge permission to invoke the Lambda Function
resource "aws_lambda_permission" "allow_eventbridge" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.uptime_checker.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.every_five_minutes.arn
}

# Additional Terraform Output
output "function_url" {
  value = aws_lambda_function_url.lambda_public_url.function_url
}


# Allow public unauthenticated access to the Lambda Function URL
# Permission 1: Grants public permission to call the Function URL
resource "aws_lambda_permission" "allow_public_function_url" {
  statement_id           = "AllowFunctionURLPublicAccess"
  action                 = "lambda:InvokeFunctionUrl"
  function_name          = aws_lambda_function.uptime_checker.function_name
  principal              = "*"
  function_url_auth_type = "NONE"
}

# Permission 2: Grants underlying invocation permissions required by AWS
resource "aws_lambda_permission" "allow_public_function_invoke" {
  statement_id  = "AllowFunctionURLInvokePublicAccess"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.uptime_checker.function_name
  principal     = "*"
}