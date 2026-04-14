# ── Database, Storage & Messaging ──────────────────────────

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

resource "aws_db_parameter_group" "this" {
  name        = "lks-pg15-params"
  family      = "postgres15"
  description = "LKS 2026 PostgreSQL 15 parameter group"

  parameter {
    name         = "rds.force_ssl"
    value        = "0"
    apply_method = "immediate"
  }

  tags = { Name = "lks-pg15-params" }

  lifecycle {
    ignore_changes        = all
    create_before_destroy = true
  }
}

resource "aws_db_subnet_group" "this" {
  name       = "lks-db-subnet-group"
  subnet_ids = var.private_subnet_ids
  tags       = { Name = "lks-db-subnet-group" }

  lifecycle {
    ignore_changes = all
  }
}

resource "aws_db_instance" "this" {
  identifier              = "lks-rds-postgres"
  engine                  = "postgres"
  engine_version          = "15"
  instance_class          = var.db_instance_class
  allocated_storage       = 20
  storage_type            = "gp2"

  db_name  = var.db_name
  username = var.db_username
  password = var.db_password

  db_subnet_group_name    = aws_db_subnet_group.this.name
  parameter_group_name    = aws_db_parameter_group.this.name
  vpc_security_group_ids  = [var.security_group_id]
  publicly_accessible     = false
  skip_final_snapshot     = true
  backup_retention_period = 7

  tags = { Name = "lks-rds-postgres" }

  lifecycle {
    ignore_changes = [password]
  }
}

resource "aws_dynamodb_table" "sessions" {
  name         = var.dynamo_table
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "sessionId"
  range_key    = "createdAt"

  attribute {
    name = "sessionId"
    type = "S"
  }
  attribute {
    name = "createdAt"
    type = "N"
  }
  ttl {
    attribute_name = "expiresAt"
    enabled        = true
  }
  point_in_time_recovery { enabled = true }
  tags = { Name = var.dynamo_table }

  lifecycle {
    ignore_changes = all
  }
}

resource "aws_sqs_queue" "dlq" {
  name = var.dlq_name
  tags = { Name = var.dlq_name }

  lifecycle {
    ignore_changes = all
  }
}

resource "aws_sqs_queue" "this" {
  name                       = var.sqs_queue_name
  visibility_timeout_seconds = 30

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = 3
  })
  tags = { Name = var.sqs_queue_name }

  lifecycle {
    ignore_changes = all
  }
}

resource "aws_ssm_parameter" "db_host" {
  name      = "/lks/app/db_host"
  type      = "String"
  value     = aws_db_instance.this.address
  overwrite = true
  tags      = { Name = "lks-ssm-db-host" }
}

resource "aws_ssm_parameter" "db_password" {
  name      = "/lks/app/db_password"
  type      = "SecureString"
  value     = var.db_password
  overwrite = true
  tags      = { Name = "lks-ssm-db-password" }
}

resource "aws_ssm_parameter" "sqs_url" {
  name      = "/lks/app/sqs_url"
  type      = "String"
  value     = aws_sqs_queue.this.url
  overwrite = true
  tags      = { Name = "lks-ssm-sqs-url" }
}

resource "aws_ssm_parameter" "dynamo_table" {
  name      = "/lks/app/dynamodb_table"
  type      = "String"
  value     = aws_dynamodb_table.sessions.name
  overwrite = true
  tags      = { Name = "lks-ssm-dynamo-table" }
}

resource "aws_sns_topic" "this" {
  name = "lks-alerts"
}

resource "aws_sns_topic_subscription" "this" {
  topic_arn = aws_sns_topic.this.arn
  protocol  = "email"
  endpoint = "hansjabriel@gmail.com"
}

resource "aws_cloudwatch_log_group" "ecs-fe" {
  name = "/ecs/lks-fe-app"
  retention_in_days = "7"

  tags = {
    Environment = "production"
    Application = "/ecs/lks-fe-app"
  }
}

resource "aws_cloudwatch_log_group" "ecs-api" {
  name = "/ecs/lks-api-app"
  retention_in_days = "7"

  tags = {
    Environment = "production"
    Application = "/ecs/lks-api-app"
  }
}

resource "aws_cloudwatch_log_group" "analytics" {
  name = "/ecs/lks-analytics-app"
  retention_in_days = "7"

  tags = {
    Environment = "production"
    Application = "/ecs/lks-analytics-app "
  }
}

resource "aws_cloudwatch_metric_alarm" "this" {
  alarm_name                = "lks-elb-failure-alarm"
  comparison_operator       = "GreaterThanThreshold"
  evaluation_periods        = 2
  metric_name               = "HTTPCode_ELB_5XX_Count"
  namespace                 = "AWS/ApplicationELB"
  period                    = 120
  statistic                 = "Average"
  threshold                 = 50
  alarm_description         = "This metric monitors ALB Failure"
}