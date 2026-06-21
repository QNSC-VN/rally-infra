terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }

  backend "s3" {
    # Shared state: ECR repos + OIDC roles — created once per AWS account
    # Override via -backend-config on first `tofu init`
    bucket         = "rally-tofu-state"
    key            = "shared/terraform.tfstate"
    region         = "ap-southeast-1"
    encrypt        = true
    dynamodb_table = "rally-tofu-locks"
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
  github_org = "nghiavt1802"   # ← update to your actual GitHub org/username
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

  github_org            = local.github_org
  create_oidc_provider  = true   # set false after first apply

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
