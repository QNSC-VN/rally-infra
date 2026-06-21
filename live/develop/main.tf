terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }

  backend "s3" {
    bucket         = "rally-tofu-state"
    key            = "develop/terraform.tfstate"
    region         = "ap-southeast-1"
    encrypt        = true
    dynamodb_table = "rally-tofu-locks"
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

locals {
  env    = "develop"
  name   = "rally-develop"
  region = "ap-southeast-1"
  azs    = ["ap-southeast-1a", "ap-southeast-1b", "ap-southeast-1c"]

  # Read shared outputs (ECR URLs + deploy role ARNs)
  # Set after first `tofu apply` of live/_shared
  ecr_api_url    = "YOUR_ACCOUNT_ID.dkr.ecr.ap-southeast-1.amazonaws.com/rally-api:latest"
  ecr_worker_url = "YOUR_ACCOUNT_ID.dkr.ecr.ap-southeast-1.amazonaws.com/rally-worker:latest"
}

# ── Networking ────────────────────────────────────────────────────────────────
module "network" {
  source = "../../modules/network"

  name   = local.name
  region = local.region
  azs    = local.azs

  vpc_cidr             = "10.10.0.0/16"
  public_subnet_cidrs  = ["10.10.0.0/24", "10.10.1.0/24", "10.10.2.0/24"]
  private_subnet_cidrs = ["10.10.10.0/24", "10.10.11.0/24", "10.10.12.0/24"]
  data_subnet_cidrs    = ["10.10.20.0/24", "10.10.21.0/24", "10.10.22.0/24"]


  multi_az_nat = false   # single NAT in staging (cost optimisation)
  app_port     = 3000

  tags = { Environment = local.env }
}

# ── Secrets (scaffolding only — fill values in Secrets Manager console) ───────
module "secrets" {
  source = "../../modules/secrets"
  prefix = "rally/${local.env}"
  tags   = { Environment = local.env }
}

# ── RDS PostgreSQL 17 ─────────────────────────────────────────────────────────
module "rds" {
  source = "../../modules/rds"

  identifier        = local.name
  subnet_ids        = module.network.data_subnet_ids
  security_group_id = module.network.sg_rds_id

  instance_class          = "db.t4g.medium"
  allocated_storage_gb    = 20
  max_allocated_storage_gb = 100
  multi_az                = false
  deletion_protection     = false   # disable in staging for easy teardown
  backup_retention_days   = 3

  tags = { Environment = local.env }
}

# ── ElastiCache Valkey ────────────────────────────────────────────────────────
module "cache" {
  source = "../../modules/cache"

  name              = local.name
  subnet_ids        = module.network.data_subnet_ids
  security_group_id = module.network.sg_cache_id

  max_data_storage_gb = 2
  max_ecpu_per_second = 2000

  tags = { Environment = local.env }
}

# ── Messaging (SQS + SNS) ─────────────────────────────────────────────────────
module "messaging" {
  source = "../../modules/messaging"
  prefix = local.name
  tags   = { Environment = local.env }
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

  tags = { Environment = local.env, Service = "api" }
}

# ── ECS Service — Worker ──────────────────────────────────────────────────────
module "worker" {
  source = "../../modules/ecs-service"

  service_name  = "worker"
  cluster_name  = module.ecs_cluster.cluster_name
  cluster_arn   = module.ecs_cluster.cluster_arn
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
  rate_limit_per_5min = 1000   # lower limit in staging

  tags = { Environment = local.env }
}
