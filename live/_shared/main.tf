terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }

  backend "s3" {
    bucket         = "qnsc-tofu-state"
    key            = "rally/shared/terraform.tfstate"
    region         = "ap-southeast-1"
    encrypt        = true
    dynamodb_table = "qnsc-tofu-locks"
  }
}

provider "aws" {
  region = "ap-southeast-1"
  default_tags {
    tags = {
      Project   = "rally"
      ManagedBy = "opentofu"
      Layer     = "shared"
    }
  }
}

locals {
  github_org = var.github_org
}

data "aws_caller_identity" "current" {}

# ── Read shared platform outputs from qnsc-infra bootstrap ───────────────────
# Gives us: kms_key_arn, artifacts_bucket_name, oidc_provider_arn
# Dependency: qnsc-infra/live/bootstrap must be applied before this stack.
data "terraform_remote_state" "platform" {
  backend = "s3"
  config = {
    bucket = "qnsc-tofu-state"
    key    = "platform/bootstrap/terraform.tfstate"
    region = "ap-southeast-1"
  }
}


# ── ECR Repositories ──────────────────────────────────────────────────────────
module "ecr" {
  source = "git::https://github.com/QNSC-VN/qnsc-tf-modules.git//modules/ecr?ref=ecr-v1.0.0"

  repository_names     = ["rally-api", "rally-worker", "rally-migrator"]
  image_tag_mutability = "MUTABLE" # allows re-tagging :latest
  kms_key_arn          = data.terraform_remote_state.platform.outputs.kms_key_arn
  tags                 = { Layer = "shared" }
}

# ── GitHub OIDC ───────────────────────────────────────────────────────────────
module "iam_oidc" {
  source = "git::https://github.com/QNSC-VN/qnsc-tf-modules.git//modules/iam-oidc?ref=iam-oidc-v1.0.0"

  product           = "rally"
  github_org        = local.github_org
  oidc_provider_arn = data.terraform_remote_state.platform.outputs.oidc_provider_arn

  environments = {
    develop = {
      allowed_subjects = [
        "repo:${local.github_org}/rally-api:ref:refs/heads/main",
        "repo:${local.github_org}/rally-api:environment:develop"
      ]
    }
    production = {
      allowed_subjects = [
        "repo:${local.github_org}/rally-api:ref:refs/heads/main",
        "repo:${local.github_org}/rally-api:ref:refs/tags/v*",
        "repo:${local.github_org}/rally-api:environment:production"
      ]
    }
  }

  app_repo_names         = ["rally-api"]
  infra_repo_name        = "rally-infra"
  ecr_repository_pattern = "rally-*"
  ecs_passrole_pattern   = "rally-*" # shared ecs-service names roles <cluster>-<service>-task
  tags                   = { Layer = "shared" }
}

# ── GitHub OIDC — rally-web deploy roles ─────────────────────────────────────
# Separate from the API roles: different repo, different permissions (S3+CF).
# Roles are environment-scoped for least-privilege S3 bucket access.
locals {
  web_deploy_envs = {
    develop = {
      allowed_subjects = [
        "repo:${local.github_org}/rally-web:ref:refs/heads/main",
        "repo:${local.github_org}/rally-web:environment:develop",
      ]
      s3_bucket = "rally-web-develop"
    }
    production = {
      allowed_subjects = [
        "repo:${local.github_org}/rally-web:ref:refs/heads/main",
        "repo:${local.github_org}/rally-web:ref:refs/tags/v*",
        "repo:${local.github_org}/rally-web:environment:production",
      ]
      s3_bucket = "rally-web-prod"
    }
  }
}

resource "aws_iam_role" "web_deploy" {
  for_each = local.web_deploy_envs

  name        = "rally-github-web-deploy-${each.key}"
  description = "Assumed by GitHub Actions to deploy rally-web to ${each.key}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Federated = data.terraform_remote_state.platform.outputs.oidc_provider_arn }
        Action    = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          }
          StringLike = {
            "token.actions.githubusercontent.com:sub" = each.value.allowed_subjects
          }
        }
      }
    ]
  })

  tags = { Layer = "shared", Environment = each.key }
}

resource "aws_iam_role_policy" "web_deploy" {
  for_each = local.web_deploy_envs

  name = "rally-web-deploy-${each.key}"
  role = aws_iam_role.web_deploy[each.key].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # S3 — sync dist/ to the environment's web bucket
      {
        Sid    = "S3Sync"
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:GetObject",
          "s3:ListBucket",
        ]
        Resource = [
          "arn:aws:s3:::${each.value.s3_bucket}",
          "arn:aws:s3:::${each.value.s3_bucket}/*",
        ]
      },
      # CloudFront — invalidate cache after deploy
      {
        Sid      = "CloudFrontInvalidate"
        Effect   = "Allow"
        Action   = ["cloudfront:CreateInvalidation", "cloudfront:GetInvalidation"]
        Resource = "arn:aws:cloudfront::${data.aws_caller_identity.current.account_id}:distribution/*"
      },
    ]
  })
}
