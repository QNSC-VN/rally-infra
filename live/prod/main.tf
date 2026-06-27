terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }

  backend "s3" {
    bucket         = "qnsc-tofu-state"
    key            = "rally/prod/terraform.tfstate"
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
      Environment = "production"
      ManagedBy   = "opentofu"
    }
  }
}

data "aws_caller_identity" "current" {}

# ── Read shared layer outputs (ECR URLs, KMS ARN, artifacts bucket) ─────────────
data "terraform_remote_state" "shared" {
  backend = "s3"
  config = {
    bucket = "qnsc-tofu-state"
    key    = "rally/shared/terraform.tfstate"
    region = "ap-southeast-1"
  }
}

locals {
  env    = "production"
  name   = "rally-prod"
  region = "ap-southeast-1"
  azs    = ["ap-southeast-1a", "ap-southeast-1b", "ap-southeast-1c"]

  kms_key_arn = data.terraform_remote_state.shared.outputs.kms_key_arn

  ecr_base       = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${local.region}.amazonaws.com"
  ecr_api_url    = "${local.ecr_base}/rally-api:latest"
  ecr_worker_url = "${local.ecr_base}/rally-worker:latest"
}

# ── Networking ────────────────────────────────────────────────────────────────
module "network" {
  source = "../../modules/network"

  name   = local.name
  region = local.region
  azs    = local.azs

  vpc_cidr             = "10.20.0.0/16"
  public_subnet_cidrs  = ["10.20.0.0/24", "10.20.1.0/24", "10.20.2.0/24"]
  private_subnet_cidrs = ["10.20.10.0/24", "10.20.11.0/24", "10.20.12.0/24"]
  data_subnet_cidrs    = ["10.20.20.0/24", "10.20.21.0/24", "10.20.22.0/24"]

  multi_az_nat = true   # one NAT per AZ in prod for HA
  app_port     = 3000

  tags = { Environment = local.env }
}

# ── Secrets ───────────────────────────────────────────────────────────────────
module "secrets" {
  source               = "../../modules/secrets"
  prefix               = "rally/${local.env}"
  kms_key_arn          = local.kms_key_arn
  recovery_window_days = 30   # longer recovery in production
  tags                 = { Environment = local.env }
}

# ── RDS PostgreSQL 17 (Multi-AZ) ─────────────────────────────────────────────
module "rds" {
  source = "../../modules/rds"

  identifier        = local.name
  subnet_ids        = module.network.data_subnet_ids
  security_group_id = module.network.sg_rds_id
  kms_key_arn       = local.kms_key_arn

  instance_class           = "db.t4g.large"
  allocated_storage_gb     = 100
  max_allocated_storage_gb = 500
  multi_az                 = true   # HA in production
  deletion_protection      = true
  backup_retention_days    = 30

  tags = { Environment = local.env }
}

# ── ElastiCache Valkey ────────────────────────────────────────────────────────
module "cache" {
  source = "../../modules/cache"

  name              = local.name
  subnet_ids        = module.network.data_subnet_ids
  security_group_id = module.network.sg_cache_id

  max_data_storage_gb      = 10
  max_ecpu_per_second      = 10000
  snapshot_retention_days  = 7

  tags = { Environment = local.env }
}

# ── Messaging ─────────────────────────────────────────────────────────────────
module "messaging" {
  source = "../../modules/messaging"

  prefix              = local.name
  dlq_max_receive_count = 3   # move to DLQ faster in production

  tags = { Environment = local.env }
}

# ── ALB ───────────────────────────────────────────────────────────────────────
resource "aws_lb" "this" {
  name               = local.name
  internal           = false
  load_balancer_type = "application"
  security_groups    = [module.network.sg_alb_id]
  subnets            = module.network.public_subnet_ids

  enable_deletion_protection = true
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
  source = "../../modules/ecs-cluster"
  name   = local.name
  tags   = { Environment = local.env }
}

# ── ECS Service — API ─────────────────────────────────────────────────────────
module "api" {
  source = "../../modules/ecs-service"

  service_name  = "api"
  cluster_name  = module.ecs_cluster.cluster_name
  cluster_arn   = module.ecs_cluster.cluster_arn
  image_uri     = local.ecr_api_url

  cpu    = 1024
  memory = 2048

  vpc_id            = module.network.vpc_id
  subnet_ids        = module.network.private_subnet_ids
  security_group_id = module.network.sg_app_id

  desired_count = 2   # at least 2 for HA
  min_count     = 2
  max_count     = 10

  attach_alb       = true
  alb_listener_arn = aws_lb_listener.https.arn
  alb_priority     = 100
  alb_path_patterns = ["/*"]
  health_check_path = "/v1/healthz"

  secret_arns = values(module.secrets.secret_arns)
  secrets = [
    { name = "DATABASE_URL",    secret_arn = module.secrets.secret_arns["db-url"] },
    { name = "REDIS_URL",       secret_arn = module.secrets.secret_arns["redis-url"] },
    { name = "JWT_PRIVATE_KEY", secret_arn = module.secrets.secret_arns["jwt-private"] },
    { name = "JWT_PUBLIC_KEY",  secret_arn = module.secrets.secret_arns["jwt-public"] },
    { name = "CSRF_SECRET",     secret_arn = module.secrets.secret_arns["csrf-secret"] },
  ]

  environment_vars = [
    { name = "NODE_ENV", value = "production" },
    { name = "PORT",     value = "3000" },
  ]

  sqs_queue_arns = values(module.messaging.queue_arns)
  sns_topic_arns = values(module.messaging.topic_arns)

  cpu_target_pct    = 60   # tighter target in prod
  memory_target_pct = 70

  tags = { Environment = local.env, Service = "api" }
}

# ── ECS Service — Worker ──────────────────────────────────────────────────────
module "worker" {
  source = "../../modules/ecs-service"

  service_name  = "worker"
  cluster_name  = module.ecs_cluster.cluster_name
  cluster_arn   = module.ecs_cluster.cluster_arn
  image_uri     = local.ecr_worker_url

  cpu    = 512
  memory = 1024

  vpc_id            = module.network.vpc_id
  subnet_ids        = module.network.private_subnet_ids
  security_group_id = module.network.sg_app_id

  desired_count = 2
  min_count     = 2
  max_count     = 6

  attach_alb = false

  health_check_command = "curl -f http://localhost:3001/v1/healthz || exit 1"
  container_port       = 3001

  secret_arns = values(module.secrets.secret_arns)
  secrets = [
    { name = "DATABASE_URL",    secret_arn = module.secrets.secret_arns["db-url"] },
    { name = "REDIS_URL",       secret_arn = module.secrets.secret_arns["redis-url"] },
    { name = "JWT_PRIVATE_KEY", secret_arn = module.secrets.secret_arns["jwt-private"] },
    { name = "JWT_PUBLIC_KEY",  secret_arn = module.secrets.secret_arns["jwt-public"] },
  ]

  environment_vars = [
    { name = "NODE_ENV", value = "production" },
  ]

  sqs_queue_arns = values(module.messaging.queue_arns)
  sns_topic_arns = values(module.messaging.topic_arns)

  tags = { Environment = local.env, Service = "worker" }
}

# ── WAF ───────────────────────────────────────────────────────────────────────
module "waf" {
  source = "../../modules/waf"

  name                = local.name
  alb_arn             = aws_lb.this.arn
  rate_limit_per_5min = 3000

  tags = { Environment = local.env }
}

# ── CDN (S3 + CloudFront) — rally-web SPA ─────────────────────────────────────
# PriceClass_All in prod — full global PoP coverage for enterprise users.
module "cdn" {
  source = "../../modules/cdn"

  name         = "rally-web-prod"
  acm_cert_arn = var.web_acm_cert_arn
  aliases      = []   # set to ["app.rally.example.com"] once DNS is configured
  price_class  = "PriceClass_All"

  tags = { Environment = local.env, Service = "web" }
}
