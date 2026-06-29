# rally-infra

OpenTofu infrastructure for the [Rally](https://github.com/QNSC-VN/rally-api) platform —
QNSC's internal Agile work-management system — deployed on AWS (ap-southeast-1).

## Architecture

```
live/
  _shared/      — ECR repositories + GitHub OIDC roles (once per AWS account)
  develop/      — Full stack: VPC, RDS, ElastiCache, ECS, ALB, WAF
  prod/         — Same as develop, Multi-AZ, larger instances

modules/
  network/      — VPC, subnets, IGW, NAT, security groups, VPC endpoints
  ecr/          — ECR repositories with lifecycle policies
  iam-oidc/     — GitHub OIDC provider + deploy roles
  rds/          — RDS PostgreSQL 17 + Secrets Manager password
  cache/        — ElastiCache Serverless (Valkey)
  messaging/    — SQS queues (with DLQs) + SNS topics
  ecs-cluster/  — ECS cluster + Fargate capacity providers
  ecs-service/  — Reusable: task def, service, ALB rule, auto-scaling
  waf/          — WAF v2 WebACL (common rules + rate limiting)
  secrets/      — Secrets Manager + SSM Parameter Store scaffolding
```

## Prerequisites

- [OpenTofu](https://opentofu.org/) ≥ 1.9.1
- S3 bucket `rally-tofu-state` + DynamoDB table `rally-tofu-locks` (create once manually)
- AWS credentials with sufficient permissions

## First-time Setup

```bash
# 1. Bootstrap remote state (one-time, run manually)
aws s3 mb s3://rally-tofu-state --region ap-southeast-1
aws s3api put-bucket-versioning --bucket rally-tofu-state \
  --versioning-configuration Status=Enabled
aws dynamodb create-table \
  --table-name rally-tofu-locks \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region ap-southeast-1

# 2. Deploy shared resources (ECR + OIDC)
cd live/_shared
tofu init && tofu apply

# 3. Deploy develop
cd live/develop
tofu init && tofu apply -var="acm_cert_arn=arn:aws:acm:..."

# 4. Deploy production (after develop is confirmed healthy)
cd live/prod
tofu init && tofu apply -var="acm_cert_arn=arn:aws:acm:..."
```

## CI/CD

| Workflow | Trigger | Action |
|----------|---------|--------|
| `plan.yml` | PR to `main` | `tofu plan` per changed workspace, posts output as PR comment |
| `apply.yml` | Push to `main` | Applies `_shared` → `develop` → `production` (prod requires approval) |

### Required Secrets (GitHub repo settings)

| Secret | Description |
|--------|-------------|
| `AWS_ACCOUNT_ID` | AWS account number |
| `ACM_CERT_ARN_DEVELOP` | ACM cert ARN for the develop ALB (ap-southeast-1) |
| `WEB_ACM_CERT_ARN_DEVELOP` | ACM cert ARN for the develop CloudFront distribution (us-east-1) |
| `ACM_CERT_ARN_PROD` | ACM cert ARN for production ALB |

### Required IAM Roles (created by `live/_shared`)

| Role | Used By |
|------|---------|
| `rally-github-infra-plan` | Plan workflow — read-only |
| `rally-github-infra-apply` | Apply workflow — write |
| `rally-github-ecr-push` | rally-api CI — push images |
| `rally-github-deploy-develop` | rally-api CD — deploy to develop |
| `rally-github-deploy-production` | rally-api CD — deploy to production |

> **Note:** `rally-github-infra-plan` and `rally-github-infra-apply` must be created manually
> before the first workflow run (they can't bootstrap themselves via OIDC).
> Use broad `AdministratorAccess` initially, then tighten after initial apply.

## Updating Application Secrets

Secrets are created as empty placeholders. Fill them in the AWS Console or via CLI:

```bash
aws secretsmanager put-secret-value \
  --secret-id rally/develop/db-url \
  --secret-string "postgresql://user:pass@host:5432/rally"
```

After the RDS module applies, the DB endpoint is available in `tofu output rds_endpoint`.

## Shared modules

This repo composes versioned modules from
[`qnsc-tf-modules`](https://github.com/QNSC-VN/qnsc-tf-modules) (network, rds,
ecs-service, cache, waf, …) — there are no local `modules/`. Each is pinned by a
per-module tag, e.g.:

```hcl
module "network" {
  source = "git::https://github.com/QNSC-VN/qnsc-tf-modules.git//modules/network?ref=network-v1.0.0"
  # ...
}
```

Bump a module deliberately by changing its `?ref=<module>-vX.Y.Z`.

## Dependency updates

Two tools keep dependencies current — each handles what it's best at:

| Tool | Updates | Config |
| :--- | :------ | :----- |
| **Renovate** | Shared Terraform module pins (`?ref=<module>-vX.Y.Z`) | [`renovate.json`](./renovate.json) |
| **Dependabot** | GitHub Actions pins (`uses: …@v1`) and any other ecosystems | `.github/dependabot.yml` |

**Why two tools:** the shared modules use *per-module prefixed* tags
(`cdn-v1.0.0`, `network-v1.0.0`). Dependabot's Terraform updater only handles
plain SemVer git refs, so it can't track these — Renovate can. The Renovate
config uses `regex` versioning with a `compatibility` capture group so each
module only updates within its own prefix (`cdn-*` never bumps to `network-*`).

> ⚠️ Renovate is a GitHub App — it must be **installed on the `QNSC-VN` org**
> for `renovate.json` to take effect. Once installed it opens a Dependency
> Dashboard issue and weekly update PRs.
