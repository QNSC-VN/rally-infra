terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

# ── ElastiCache Serverless (Valkey-compatible) ────────────────────────────────
# Note: ElastiCache Serverless natively supports Valkey and Redis protocols.
resource "aws_elasticache_serverless_cache" "this" {
  engine = "valkey"
  name   = var.name

  cache_usage_limits {
    data_storage {
      maximum = var.max_data_storage_gb
      unit    = "GB"
    }
    ecpu_per_second {
      maximum = var.max_ecpu_per_second
    }
  }

  daily_snapshot_time      = "04:30"
  snapshot_retention_limit = var.snapshot_retention_days

  subnet_ids         = var.subnet_ids
  security_group_ids = [var.security_group_id]

  kms_key_id = var.kms_key_arn != "" ? var.kms_key_arn : null

  major_engine_version = var.engine_version

  tags = merge(var.tags, { Name = var.name })
}
