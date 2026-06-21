terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

# ── Secrets Manager — application secrets ────────────────────────────────────
# These are created as empty secrets; actual values must be set out-of-band
# (console, CI/CD, or aws-cli), then referenced by ECS tasks.

resource "aws_secretsmanager_secret" "app" {
  for_each = var.secret_names

  name                    = "${var.prefix}/${each.key}"
  description             = each.value
  recovery_window_in_days = var.recovery_window_days
  kms_key_id              = var.kms_key_arn != "" ? var.kms_key_arn : null

  tags = merge(var.tags, { Name = "${var.prefix}/${each.key}" })
}

# ── SSM Parameter Store — non-sensitive config ────────────────────────────────
resource "aws_ssm_parameter" "config" {
  for_each = var.ssm_parameters

  name        = "/${var.prefix}/${each.key}"
  type        = "String"
  value       = each.value.value
  description = each.value.description

  tags = merge(var.tags, { Name = "/${var.prefix}/${each.key}" })
}
