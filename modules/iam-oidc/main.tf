terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

data "aws_caller_identity" "current" {}

# ── GitHub OIDC Provider (one per AWS account) ────────────────────────────────
# Skip creation if it already exists (common to share across projects).
resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_oidc_provider ? 1 : 0

  url = "https://token.actions.githubusercontent.com"

  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]

  tags = var.tags
}

locals {
  oidc_provider_arn = var.create_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : var.existing_oidc_provider_arn
}

# ── Per-environment deploy roles ──────────────────────────────────────────────
resource "aws_iam_role" "deploy" {
  for_each = var.environments

  name        = "rally-github-deploy-${each.key}"
  description = "Assumed by GitHub Actions to deploy rally to ${each.key}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Federated = local.oidc_provider_arn }
        Action    = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          }
          # Restrict by repo and ref (branch or tag)
          StringLike = {
            "token.actions.githubusercontent.com:sub" = each.value.allowed_subjects
          }
        }
      }
    ]
  })

  tags = merge(var.tags, { Environment = each.key })
}

# Inline policy: ECS deploy + ECR pull permissions per environment
resource "aws_iam_role_policy" "deploy" {
  for_each = var.environments
  name     = "rally-deploy-${each.key}"
  role     = aws_iam_role.deploy[each.key].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # ECR — get auth token
      {
        Sid      = "ECRAuth"
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      # ECR — push/pull on rally repos
      {
        Sid    = "ECRPushPull"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:PutImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:DescribeRepositories",
          "ecr:ListImages"
        ]
        Resource = "arn:aws:ecr:*:${data.aws_caller_identity.current.account_id}:repository/rally-*"
      },
      # ECS — describe + register task definitions + update services
      {
        Sid    = "ECSDeployCore"
        Effect = "Allow"
        Action = [
          "ecs:DescribeTaskDefinition",
          "ecs:RegisterTaskDefinition",
          "ecs:DescribeServices",
          "ecs:UpdateService",
          "ecs:RunTask",
          "ecs:DescribeTasks",
          "ecs:ListTaskDefinitions"
        ]
        Resource = "*"
      },
      # IAM — allow ECS to pass the task/execution roles
      {
        Sid      = "PassRoleToECS"
        Effect   = "Allow"
        Action   = ["iam:PassRole"]
        Resource = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/rally-ecs-*"
      },
      # Logs — describe log groups (for ECS task logging)
      {
        Sid      = "Logs"
        Effect   = "Allow"
        Action   = ["logs:DescribeLogGroups"]
        Resource = "*"
      }
    ]
  })
}

# ── Shared ECR push role (used by the build-push job, no environment gate) ────
resource "aws_iam_role" "ecr_push" {
  name        = "rally-github-ecr-push"
  description = "Assumed by GitHub Actions build jobs to push images to ECR"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Federated = local.oidc_provider_arn }
        Action    = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          }
          StringLike = {
            "token.actions.githubusercontent.com:sub" = "repo:${var.github_org}/*:*"
          }
        }
      }
    ]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "ecr_push" {
  name = "rally-ecr-push"
  role = aws_iam_role.ecr_push.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:PutImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload"
        ]
        Resource = "arn:aws:ecr:*:${data.aws_caller_identity.current.account_id}:repository/rally-*"
      }
    ]
  })
}

# ── Infra CI roles (rally-infra repo) ─────────────────────────────────────────
locals {
  infra_subject_base = "repo:${var.github_org}/${var.infra_repo_name}"
}

# Read-only plan role — used by plan.yml on PRs
resource "aws_iam_role" "infra_plan" {
  name        = "rally-github-infra-plan"
  description = "Assumed by GitHub Actions to run tofu plan on rally-infra PRs"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = local.oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        StringLike = {
          "token.actions.githubusercontent.com:sub" = "${local.infra_subject_base}:*"
        }
      }
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "infra_plan_readonly" {
  role       = aws_iam_role.infra_plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

# Apply role — used by apply.yml on push to main (broad permissions, protected by branch rules)
resource "aws_iam_role" "infra_apply" {
  name        = "rally-github-infra-apply"
  description = "Assumed by GitHub Actions to run tofu apply on rally-infra main branch"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = local.oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          # Restrict to main branch only
          "token.actions.githubusercontent.com:sub" = "${local.infra_subject_base}:ref:refs/heads/main"
        }
      }
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "infra_apply_admin" {
  role       = aws_iam_role.infra_apply.name
  # Start with AdministratorAccess; tighten after initial apply
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}
