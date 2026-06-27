terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }

  backend "s3" {
    bucket         = "qncs-tofu-state"
    key            = "rally/shared/terraform.tfstate"
    region         = "ap-southeast-1"
    encrypt        = true
    dynamodb_table = "qncs-tofu-locks"
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

# ── Read shared platform outputs from qncs-infra bootstrap ───────────────────
# Gives us: kms_key_arn, artifacts_bucket_name, oidc_provider_arn
# Dependency: qncs-infra/live/bootstrap must be applied before this stack.
data "terraform_remote_state" "platform" {
  backend = "s3"
  config = {
    bucket = "qncs-tofu-state"
    key    = "platform/bootstrap/terraform.tfstate"
    region = "ap-southeast-1"
  }
}

# ── Discover the GitHub OIDC provider provisioned by qncs-infra bootstrap ────
# One OIDC provider exists per AWS account (AWS hard limit).
# qncs-infra/live/bootstrap owns creation; rally-infra must never create it.
data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

# ── ECR Repositories ──────────────────────────────────────────────────────────
module "ecr" {
  source = "../../modules/ecr"

  repository_names = ["rally-api", "rally-worker", "rally-migrator"]
  tags             = { Layer = "shared" }
}

# ── GitHub OIDC ───────────────────────────────────────────────────────────────
module "iam_oidc" {
  source = "../../modules/iam-oidc"

  github_org                 = local.github_org
  create_oidc_provider       = false   # qncs-infra owns the provider — never recreate
  existing_oidc_provider_arn = data.aws_iam_openid_connect_provider.github.arn

  environments = {
    develop = {
      allowed_subjects = [
        "repo:${local.github_org}/rally-api:ref:refs/heads/main"
      ]
    }
    production = {
      allowed_subjects = [
        "repo:${local.github_org}/rally-api:ref:refs/heads/main",
        "repo:${local.github_org}/rally-api:ref:refs/tags/v*"
      ]
    }
  }

  tags = { Layer = "shared" }
}

# ── GitHub OIDC — rally-web deploy roles ─────────────────────────────────────
# Separate from the API roles: different repo, different permissions (S3+CF).
# Roles are environment-scoped for least-privilege S3 bucket access.
locals {
  web_deploy_envs = {
    develop = {
      allowed_subjects = [
        "repo:${local.github_org}/rally-web:ref:refs/heads/main",
      ]
      s3_bucket = "rally-web-develop"
    }
    production = {
      allowed_subjects = [
        "repo:${local.github_org}/rally-web:ref:refs/heads/main",
        "repo:${local.github_org}/rally-web:ref:refs/tags/v*",
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
        Principal = { Federated = module.iam_oidc.oidc_provider_arn }
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
        Action   = ["cloudfront:CreateInvalidation"]
        Resource = "arn:aws:cloudfront::${data.aws_caller_identity.current.account_id}:distribution/*"
      },
    ]
  })
}
