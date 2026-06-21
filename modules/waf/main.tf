terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

# ── WAF v2 WebACL ─────────────────────────────────────────────────────────────
resource "aws_wafv2_web_acl" "this" {
  name        = var.name
  description = "WAF ACL for Rally ALB"
  scope       = "REGIONAL"

  default_action {
    allow {}
  }

  # 1. AWS Managed Rules — Common Rule Set
  rule {
    name     = "AWSManagedRulesCommonRuleSet"
    priority = 1
    override_action { none {} }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name}-common-rules"
      sampled_requests_enabled   = true
    }
  }

  # 2. AWS Managed Rules — Known Bad Inputs
  rule {
    name     = "AWSManagedRulesKnownBadInputsRuleSet"
    priority = 2
    override_action { none {} }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name}-bad-inputs"
      sampled_requests_enabled   = true
    }
  }

  # 3. IP Rate Limiting
  rule {
    name     = "RateLimitPerIP"
    priority = 10
    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit              = var.rate_limit_per_5min
        aggregate_key_type = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name}-rate-limit"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.name}-webacl"
    sampled_requests_enabled   = true
  }

  tags = merge(var.tags, { Name = var.name })
}

# ── Associate with ALB ─────────────────────────────────────────────────────────
resource "aws_wafv2_web_acl_association" "this" {
  count        = var.alb_arn != "" ? 1 : 0
  resource_arn = var.alb_arn
  web_acl_arn  = aws_wafv2_web_acl.this.arn
}

# ── CloudWatch log group for WAF ──────────────────────────────────────────────
resource "aws_cloudwatch_log_group" "waf" {
  # WAF requires the name to start with "aws-waf-logs-"
  name              = "aws-waf-logs-${var.name}"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

resource "aws_wafv2_web_acl_logging_configuration" "this" {
  log_destination_configs = [aws_cloudwatch_log_group.waf.arn]
  resource_arn            = aws_wafv2_web_acl.this.arn

  logging_filter {
    default_behavior = "KEEP"
    filter {
      behavior    = "DROP"
      requirement = "MEETS_ANY"
      condition {
        action_condition { action = "ALLOW" }
      }
    }
  }
}
