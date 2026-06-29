terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }

  backend "s3" {
    bucket         = "qnsc-tofu-state"
    key            = "rally/develop/terraform.tfstate"
    region         = "ap-southeast-1"
    encrypt        = true
    dynamodb_table = "qnsc-tofu-locks"
  }
}

provider "aws" {
  region = "ap-southeast-1"
  default_tags {
    tags = {
      Project     = "rally"
      Environment = "develop"
      ManagedBy   = "opentofu"
    }
  }
}

data "aws_caller_identity" "current" {}

# ── Read shared layer outputs (ECR URLs, KMS ARN, artifacts bucket) ───────────
# _shared owns ECR repos and re-exports platform-level outputs from qnsc-infra.
# Dependency: rally-infra/_shared must be applied before this environment stack.
data "terraform_remote_state" "shared" {
  backend = "s3"
  config = {
    bucket = "qnsc-tofu-state"
    key    = "rally/shared/terraform.tfstate"
    region = "ap-southeast-1"
  }
}

locals {
  env    = "develop"
  name   = "rally-develop"
  region = "ap-southeast-1"
  azs    = ["ap-southeast-1a", "ap-southeast-1b", "ap-southeast-1c"]

  kms_key_arn = data.terraform_remote_state.shared.outputs.kms_key_arn

  # ECR URLs derived from current AWS account — no hardcoded placeholder
  ecr_base       = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${local.region}.amazonaws.com"
  ecr_api_url      = "${local.ecr_base}/rally-api:latest"
  ecr_worker_url   = "${local.ecr_base}/rally-worker:latest"
  ecr_migrator_url = "${local.ecr_base}/rally-migrator:latest"
}

# ── Networking ────────────────────────────────────────────────────────────────
module "network" {
  source = "git::https://github.com/QNSC-VN/qnsc-tf-modules.git//modules/network?ref=network-v1.0.0"

  name   = local.name
  region = local.region
  azs    = local.azs

  enable_interface_endpoints = false # dev: NAT already covers egress — save ~$22/mo

  vpc_cidr             = "10.10.0.0/16"
  public_subnet_cidrs  = ["10.10.0.0/24", "10.10.1.0/24", "10.10.2.0/24"]
  private_subnet_cidrs = ["10.10.10.0/24", "10.10.11.0/24", "10.10.12.0/24"]
  data_subnet_cidrs    = ["10.10.20.0/24", "10.10.21.0/24", "10.10.22.0/24"]


  multi_az_nat             = false   # single NAT in staging (cost optimisation)
  app_port                 = 3000
  enable_flow_logs         = true
  flow_log_retention_days  = 30

  tags = { Environment = local.env }
}

# ── Secrets (scaffolding only — fill values in Secrets Manager console) ───────
module "secrets" {
  source      = "git::https://github.com/QNSC-VN/qnsc-tf-modules.git//modules/secrets?ref=secrets-v1.0.0"
  prefix      = "rally/${local.env}"
  kms_key_arn = local.kms_key_arn

  secret_names = {
    "db-url"      = "PostgreSQL connection URL for the app"
    "jwt-private" = "Ed25519 private key (PEM, base64-encoded)"
    "jwt-public"  = "Ed25519 public key (PEM, base64-encoded)"
    "csrf-secret" = "CSRF token signing secret"
    "redis-url"   = "Redis/Valkey connection URL"
  }

  tags = { Environment = local.env }
}

# ── RDS PostgreSQL 17 ─────────────────────────────────────────────────────────
module "rds" {
  source = "git::https://github.com/QNSC-VN/qnsc-tf-modules.git//modules/rds?ref=rds-v1.0.1"

  identifier        = local.name
  subnet_ids        = module.network.data_subnet_ids
  security_group_id = module.network.sg_rds_id
  kms_key_arn       = local.kms_key_arn

  instance_class          = "db.t4g.medium"
  allocated_storage_gb    = 20
  max_allocated_storage_gb = 100
  multi_az                = false
  deletion_protection     = false   # disable in staging for easy teardown
  backup_retention_days   = 3
  monitoring_interval     = 0       # disable Enhanced Monitoring in develop (saves CloudWatch cost)

  tags = { Environment = local.env, AutoStop = "true" }
}

# ── ElastiCache Valkey ────────────────────────────────────────────────────────
module "cache" {
  source = "git::https://github.com/QNSC-VN/qnsc-tf-modules.git//modules/cache?ref=cache-v1.0.0"

  name              = local.name
  subnet_ids        = module.network.data_subnet_ids
  security_group_id = module.network.sg_cache_id

  mode = "node" # dev: single small node (~$11/mo) vs serverless ~$90 floor

  tags = { Environment = local.env }
}

# ── Messaging (SQS + SNS) ─────────────────────────────────────────────────────
module "messaging" {
  source = "git::https://github.com/QNSC-VN/qnsc-tf-modules.git//modules/messaging?ref=messaging-v1.0.0"
  prefix = local.name

  queues = {
    notifications = {}
    audit         = { visibility_timeout = 60 }
    reporting     = { visibility_timeout = 300 }
    search        = {}
  }

  topics = ["domain-events"]

  subscriptions = [
    {
      topic         = "domain-events"
      queue         = "notifications"
      filter_policy = jsonencode({ eventType = ["notification.created", "notification.updated"] })
    }
  ]

  tags = { Environment = local.env }
}

# ── ALB ───────────────────────────────────────────────────────────────────────
resource "aws_lb" "this" {
  name               = local.name
  internal           = false
  load_balancer_type = "application"
  security_groups    = [module.network.sg_alb_id]
  subnets            = module.network.public_subnet_ids

  enable_deletion_protection = false
  drop_invalid_header_fields = true

  tags = { Name = local.name, Environment = local.env }
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.acm_cert_arn

  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "Not found"
      status_code  = "404"
    }
  }
}

resource "aws_lb_listener" "http_redirect" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

# ── ECS Cluster ───────────────────────────────────────────────────────────────
module "ecs_cluster" {
  source = "git::https://github.com/QNSC-VN/qnsc-tf-modules.git//modules/ecs-cluster?ref=ecs-cluster-v1.0.0"
  name   = local.name
  tags   = { Environment = local.env }
}

# ── ECS Service — API ─────────────────────────────────────────────────────────
module "api" {
  source = "git::https://github.com/QNSC-VN/qnsc-tf-modules.git//modules/ecs-service?ref=ecs-service-v1.0.0"

  service_name  = "api"
  cluster_name  = module.ecs_cluster.cluster_name
  cluster_arn   = module.ecs_cluster.cluster_arn
  region        = local.region
  image_uri     = local.ecr_api_url

  cpu    = 512
  memory = 1024

  vpc_id            = module.network.vpc_id
  subnet_ids        = module.network.private_subnet_ids
  security_group_id = module.network.sg_app_id

  desired_count = 1
  min_count     = 1
  max_count     = 3

  attach_alb       = true
  alb_listener_arn = aws_lb_listener.https.arn
  alb_priority     = 100
  alb_path_patterns = ["/*"]
  health_check_path = "/v1/healthz"

  secret_arns = values(module.secrets.secret_arns)
  kms_key_arn = local.kms_key_arn
  secrets = [
    { name = "DATABASE_URL",    secret_arn = module.secrets.secret_arns["db-url"] },
    { name = "REDIS_URL",       secret_arn = module.secrets.secret_arns["redis-url"] },
    { name = "JWT_PRIVATE_KEY", secret_arn = module.secrets.secret_arns["jwt-private"] },
    { name = "JWT_PUBLIC_KEY",  secret_arn = module.secrets.secret_arns["jwt-public"] },
    { name = "CSRF_SECRET",     secret_arn = module.secrets.secret_arns["csrf-secret"] },
  ]

  environment_vars = [
    { name = "NODE_ENV",               value = "production" },
    { name = "PORT",                   value = "3000" },
    { name = "AWS_REGION",             value = local.region },
    { name = "CORS_ORIGINS",           value = "https://rally-dev.qnsc.vn,https://${module.cdn.cloudfront_domain}" },
    { name = "APP_BASE_URL",           value = "https://rally-dev.qnsc.vn" },
    # JWT config — defaults match app .env.example; override if needed
    { name = "JWT_ISSUER",             value = "rally-api" },
    { name = "JWT_AUDIENCE",           value = "rally-web" },
    { name = "JWT_ACCESS_EXPIRY",      value = "15m" },
    { name = "JWT_REFRESH_EXPIRY",     value = "30d" },
    # Microsoft Entra SSO — set tenant/client IDs; leave empty to disable SSO
    { name = "ENTRA_TENANT_ID",        value = var.entra_tenant_id },
    { name = "ENTRA_CLIENT_ID",        value = var.entra_client_id },
    # Messaging — SQS queue URLs injected at deploy time from module outputs
    { name = "SQS_NOTIFICATIONS_URL",  value = module.messaging.queue_urls["notifications"] },
    { name = "SQS_AUDIT_URL",          value = module.messaging.queue_urls["audit"] },
    { name = "SQS_REPORTING_URL",      value = module.messaging.queue_urls["reporting"] },
    { name = "SQS_SEARCH_URL",         value = module.messaging.queue_urls["search"] },
    { name = "SNS_TOPIC_ARN",          value = module.messaging.topic_arns["domain-events"] },
    # S3 attachments bucket
    { name = "S3_ATTACHMENTS_BUCKET",  value = aws_s3_bucket.attachments.bucket },
    # Email — SES in production
    { name = "EMAIL_PROVIDER",         value = "ses" },
    # Observability
    { name = "LOG_LEVEL",              value = "info" },
    { name = "LOG_PRETTY",             value = "false" },
    { name = "OTEL_ENABLED",           value = "false" },
    { name = "OTEL_SERVICE_NAME",      value = "rally-api" },
  ]

  sqs_queue_arns = values(module.messaging.queue_arns)
  sns_topic_arns = values(module.messaging.topic_arns)

  tags = { Environment = local.env, Service = "api", AutoStop = "true" }
}

# ── ECS Service — Worker ──────────────────────────────────────────────────────
module "worker" {
  source = "git::https://github.com/QNSC-VN/qnsc-tf-modules.git//modules/ecs-service?ref=ecs-service-v1.0.0"

  service_name  = "worker"
  cluster_name  = module.ecs_cluster.cluster_name
  cluster_arn   = module.ecs_cluster.cluster_arn
  region        = local.region
  image_uri     = local.ecr_worker_url

  cpu    = 256
  memory = 512

  vpc_id            = module.network.vpc_id
  subnet_ids        = module.network.private_subnet_ids
  security_group_id = module.network.sg_app_id

  desired_count = 1
  min_count     = 1
  max_count     = 2

  attach_alb = false

  # Worker has no HTTP listener — check the node process is alive instead
  health_check_command = "pgrep -x node || exit 1"
  container_port       = 3001

  secret_arns = values(module.secrets.secret_arns)
  kms_key_arn = local.kms_key_arn
  secrets = [
    { name = "DATABASE_URL",    secret_arn = module.secrets.secret_arns["db-url"] },
    { name = "REDIS_URL",       secret_arn = module.secrets.secret_arns["redis-url"] },
    { name = "JWT_PRIVATE_KEY", secret_arn = module.secrets.secret_arns["jwt-private"] },
    { name = "JWT_PUBLIC_KEY",  secret_arn = module.secrets.secret_arns["jwt-public"] },
    # Shared schema requires CSRF_SECRET even though the worker never uses it as middleware
    { name = "CSRF_SECRET",     secret_arn = module.secrets.secret_arns["csrf-secret"] },
  ]

  environment_vars = [
    { name = "NODE_ENV",              value = "production" },
    { name = "AWS_REGION",            value = local.region },
    { name = "SQS_NOTIFICATIONS_URL", value = module.messaging.queue_urls["notifications"] },
    { name = "SQS_AUDIT_URL",         value = module.messaging.queue_urls["audit"] },
    { name = "SQS_REPORTING_URL",     value = module.messaging.queue_urls["reporting"] },
    { name = "SQS_SEARCH_URL",        value = module.messaging.queue_urls["search"] },
    { name = "SNS_TOPIC_ARN",         value = module.messaging.topic_arns["domain-events"] },
    { name = "S3_ATTACHMENTS_BUCKET", value = aws_s3_bucket.attachments.bucket },
    { name = "EMAIL_PROVIDER",        value = "ses" },
    { name = "LOG_LEVEL",             value = "info" },
    { name = "LOG_PRETTY",            value = "false" },
    { name = "OTEL_ENABLED",          value = "false" },
    { name = "OTEL_SERVICE_NAME",     value = "rally-worker" },
  ]

  sqs_queue_arns = values(module.messaging.queue_arns)
  sns_topic_arns = values(module.messaging.topic_arns)

  tags = { Environment = local.env, Service = "worker", AutoStop = "true" }
}

# ── S3 — Attachments bucket ───────────────────────────────────────────────────
resource "aws_s3_bucket" "attachments" {
  bucket = "${local.name}-attachments"
  tags   = { Name = "${local.name}-attachments", Environment = local.env }
}

resource "aws_s3_bucket_public_access_block" "attachments" {
  bucket                  = aws_s3_bucket.attachments.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "attachments" {
  bucket = aws_s3_bucket.attachments.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = local.kms_key_arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_cors_configuration" "attachments" {
  bucket = aws_s3_bucket.attachments.id
  cors_rule {
    allowed_headers = ["Content-Type", "Content-Disposition"]
    allowed_methods = ["PUT"]
    allowed_origins = [
      "https://rally-dev.qnsc.vn",
      "https://${module.cdn.cloudfront_domain}",
      "http://localhost:5173",
    ]
    expose_headers  = ["ETag"]
    max_age_seconds = 3600
  }
}

# ── WAF ───────────────────────────────────────────────────────────────────────
resource "aws_cloudwatch_log_group" "migrator" {
  name              = "/ecs/${local.name}/migrator"
  retention_in_days = 30
  tags              = { Environment = local.env, Service = "migrator" }
}

# ── ECS Task Definition — Migrator (one-shot, run manually or via CI) ─────────
# This task runs `pnpm migration:run` then exits. It is never scheduled as a
# service; deploy pipelines trigger it with: aws ecs run-task ...
resource "aws_ecs_task_definition" "migrator" {
  family                   = "${local.name}-migrator"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 512
  memory                   = 1024
  execution_role_arn       = module.api.execution_role_arn
  task_role_arn            = module.api.task_role_arn

  container_definitions = jsonencode([{
    name      = "migrator"
    image     = local.ecr_migrator_url
    essential = true

    environment = [
      { name = "NODE_ENV",        value = "production" },
      { name = "AWS_REGION",      value = local.region },
      { name = "SEED_ON_DEPLOY",  value = "true" },
    ]

    secrets = [
      # The migrator uses the same DATABASE_URL (rallyadmin has full DDL rights)
      { name = "DATABASE_URL", valueFrom = module.secrets.secret_arns["db-url"] },
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.migrator.name
        "awslogs-region"        = local.region
        "awslogs-stream-prefix" = "migrator"
      }
    }
  }])

  tags = { Environment = local.env, Service = "migrator" }
}

module "waf" {
  source = "git::https://github.com/QNSC-VN/qnsc-tf-modules.git//modules/waf?ref=waf-v1.0.1"

  name                = local.name
  enabled             = false   # WAF skipped in develop — saves $5+/month per WebACL; enabled in prod
  alb_arn             = aws_lb.this.arn
  rate_limit_per_5min = 1000

  tags = { Environment = local.env }
}

# ── CDN (S3 + CloudFront) — rally-web SPA ─────────────────────────────────────
# Prerequisites:
#   1. Create an ACM cert for the web domain in us-east-1 (CloudFront requirement)
#   2. Pass its ARN as web_acm_cert_arn in your tfvars
#   3. After apply: set S3_BUCKET + CLOUDFRONT_ID as GitHub env vars for rally-web
module "cdn" {
  source = "git::https://github.com/QNSC-VN/qnsc-tf-modules.git//modules/cdn?ref=cdn-v1.0.0"

  name         = "rally-web-develop"
  acm_cert_arn = var.web_acm_cert_arn
  # Custom alias deferred: the CNAME was held by the just-deleted old distribution
  # (CloudFront alias release lags) + no DNS points here yet in dev. Restore
  # ["rally-dev.qnsc.vn"] once DNS is configured and the alias lock clears.
  aliases     = ["rally-dev.qnsc.vn"]
  price_class = "PriceClass_100" # develop: US/EU PoPs only — cheaper than PriceClass_200

  tags = { Environment = local.env, Service = "web" }
}

# ── Dev cost saver: stop RDS + scale ECS to 0 off-hours ───────────────────────
# Acts on resources tagged AutoStop=true (rds, api, worker above).
module "dev_scheduler" {
  source = "git::https://github.com/QNSC-VN/qnsc-tf-modules.git//modules/dev-scheduler?ref=dev-scheduler-v1.0.0"
  name   = local.name
  tags   = { Environment = local.env }
}

