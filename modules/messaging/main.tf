terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

locals {
  # Queue definitions: queue_name → config overrides (all optional)
  queues = {
    notifications = {}
    audit         = { visibility_timeout = 60 }
    reporting     = { visibility_timeout = 300 }
    search        = {}
  }
}

# ── SQS Dead-Letter Queues ────────────────────────────────────────────────────
resource "aws_sqs_queue" "dlq" {
  for_each = local.queues

  name                       = "${var.prefix}-${each.key}-dlq"
  message_retention_seconds  = 1209600   # 14 days
  sqs_managed_sse_enabled    = true

  tags = merge(var.tags, { Name = "${var.prefix}-${each.key}-dlq", Role = "dlq" })
}

# ── SQS Main Queues ───────────────────────────────────────────────────────────
resource "aws_sqs_queue" "main" {
  for_each = local.queues

  name                       = "${var.prefix}-${each.key}"
  visibility_timeout_seconds = lookup(each.value, "visibility_timeout", 30)
  message_retention_seconds  = 345600   # 4 days
  max_message_size           = 262144   # 256 KB
  delay_seconds              = 0
  receive_wait_time_seconds  = 20       # long polling
  sqs_managed_sse_enabled    = true

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq[each.key].arn
    maxReceiveCount     = var.dlq_max_receive_count
  })

  tags = merge(var.tags, { Name = "${var.prefix}-${each.key}" })
}

# ── SQS Queue Policies (allow SNS to send) ────────────────────────────────────
resource "aws_sqs_queue_policy" "main" {
  for_each  = aws_sqs_queue.main
  queue_url = each.value.url

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowSNSPublish"
        Effect = "Allow"
        Principal = { Service = "sns.amazonaws.com" }
        Action    = "sqs:SendMessage"
        Resource  = each.value.arn
        Condition = {
          ArnLike = { "aws:SourceArn" = "arn:aws:sns:*:*:${var.prefix}-*" }
        }
      }
    ]
  })
}

# ── SNS Topics ────────────────────────────────────────────────────────────────
resource "aws_sns_topic" "events" {
  for_each          = toset(var.sns_topic_names)
  name              = "${var.prefix}-${each.key}"
  kms_master_key_id = var.kms_key_arn != "" ? var.kms_key_arn : "alias/aws/sns"
  tags              = merge(var.tags, { Name = "${var.prefix}-${each.key}" })
}

# ── SNS → SQS subscriptions (notifications topic → notifications queue) ───────
resource "aws_sns_topic_subscription" "notifications" {
  count = contains(var.sns_topic_names, "domain-events") ? 1 : 0

  topic_arn = aws_sns_topic.events["domain-events"].arn
  protocol  = "sqs"
  endpoint  = aws_sqs_queue.main["notifications"].arn

  filter_policy = jsonencode({
    eventType = ["notification.created", "notification.updated"]
  })
}
