terraform {
  required_providers {
    aws   = { source = "hashicorp/aws", version = "~> 5.0" }
    random = { source = "hashicorp/random", version = "~> 3.0" }
  }
}

# ── DB Subnet Group ───────────────────────────────────────────────────────────
resource "aws_db_subnet_group" "this" {
  name       = var.identifier
  subnet_ids = var.subnet_ids
  tags       = merge(var.tags, { Name = var.identifier })
}

# ── Parameter Group (PostgreSQL 17) ───────────────────────────────────────────
resource "aws_db_parameter_group" "this" {
  name   = "${var.identifier}-pg17"
  family = "postgres17"

  parameter {
    name  = "shared_preload_libraries"
    value = "pg_stat_statements"
  }
  parameter {
    name  = "log_min_duration_statement"
    value = tostring(var.log_min_duration_ms)
  }
  parameter {
    name  = "log_connections"
    value = "1"
  }
  parameter {
    name  = "log_disconnections"
    value = "1"
  }

  tags = var.tags
}

# ── Master password in Secrets Manager ───────────────────────────────────────
resource "random_password" "master" {
  length           = 32
  special          = true
  override_special = "!#$%&*()-_=+[]{}|;:,.<>?"
}

resource "aws_secretsmanager_secret" "db_master" {
  name                    = "${var.identifier}/db-master-password"
  recovery_window_in_days = var.secret_recovery_days
  tags                    = var.tags
}

resource "aws_secretsmanager_secret_version" "db_master" {
  secret_id = aws_secretsmanager_secret.db_master.id
  secret_string = jsonencode({
    username = var.master_username
    password = random_password.master.result
    dbname   = var.database_name
    port     = 5432
    engine   = "postgres"
  })
}

# ── RDS Instance (PostgreSQL 17) ──────────────────────────────────────────────
resource "aws_db_instance" "this" {
  identifier     = var.identifier
  engine         = "postgres"
  engine_version = "17"
  instance_class = var.instance_class

  allocated_storage     = var.allocated_storage_gb
  max_allocated_storage = var.max_allocated_storage_gb
  storage_type          = "gp3"
  storage_encrypted     = true
  kms_key_id            = var.kms_key_arn != "" ? var.kms_key_arn : null

  db_name  = var.database_name
  username = var.master_username
  password = random_password.master.result

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [var.security_group_id]
  parameter_group_name   = aws_db_parameter_group.this.name

  multi_az            = var.multi_az
  publicly_accessible = false
  deletion_protection = var.deletion_protection

  backup_retention_period   = var.backup_retention_days
  backup_window             = "03:00-04:00"   # UTC
  maintenance_window        = "Mon:04:30-Mon:06:00"
  auto_minor_version_upgrade = true
  apply_immediately          = false

  performance_insights_enabled          = true
  performance_insights_retention_period = 7    # free tier

  monitoring_interval = var.monitoring_interval
  monitoring_role_arn = var.monitoring_interval > 0 ? aws_iam_role.rds_enhanced[0].arn : null

  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]

  skip_final_snapshot       = !var.deletion_protection
  final_snapshot_identifier = var.deletion_protection ? "${var.identifier}-final" : null

  copy_tags_to_snapshot = true

  tags = merge(var.tags, { Name = var.identifier })

  lifecycle {
    ignore_changes = [password]   # rotated externally via Secrets Manager
  }
}

# ── Enhanced monitoring IAM role ──────────────────────────────────────────────
resource "aws_iam_role" "rds_enhanced" {
  count = var.monitoring_interval > 0 ? 1 : 0
  name  = "${var.identifier}-rds-enhanced-monitoring"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "monitoring.rds.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "rds_enhanced" {
  count      = var.monitoring_interval > 0 ? 1 : 0
  role       = aws_iam_role.rds_enhanced[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}
