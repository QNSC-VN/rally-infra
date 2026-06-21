# rally-infra

OpenTofu infrastructure for the [Rally](../rally-api) project deployed on AWS (ap-southeast-1).

## Architecture

```
live/
  _shared/      — ECR repositories + GitHub OIDC roles (once per AWS account)
  staging/      — Full stack: VPC, RDS, ElastiCache, ECS, ALB, WAF
  prod/         — Same as staging, Multi-AZ, larger instances

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

# 3. Deploy staging
cd live/staging
tofu init && tofu apply -var="acm_cert_arn=arn:aws:acm:..."

# 4. Deploy production (after staging is confirmed healthy)
cd live/prod
tofu init && tofu apply -var="acm_cert_arn=arn:aws:acm:..."
```

## CI/CD

| Workflow | Trigger | Action |
|----------|---------|--------|
| `plan.yml` | PR to `main` | `tofu plan` per changed workspace, posts output as PR comment |
| `apply.yml` | Push to `main` | Applies `_shared` → `staging` → `production` (prod requires approval) |

### Required Secrets (GitHub repo settings)

| Secret | Description |
|--------|-------------|
| `AWS_ACCOUNT_ID` | AWS account number |
| `ACM_CERT_ARN_STAGING` | ACM cert ARN for staging ALB |
| `ACM_CERT_ARN_PROD` | ACM cert ARN for production ALB |

### Required IAM Roles (created by `live/_shared`)

| Role | Used By |
|------|---------|
| `rally-github-infra-plan` | Plan workflow — read-only |
| `rally-github-infra-apply` | Apply workflow — write |
| `rally-github-ecr-push` | rally-api CI — push images |
| `rally-github-deploy-staging` | rally-api CD — deploy to staging |
| `rally-github-deploy-production` | rally-api CD — deploy to production |

> **Note:** `rally-github-infra-plan` and `rally-github-infra-apply` must be created manually
> before the first workflow run (they can't bootstrap themselves via OIDC).
> Use broad `AdministratorAccess` initially, then tighten after initial apply.

## Updating Application Secrets

Secrets are created as empty placeholders. Fill them in the AWS Console or via CLI:

```bash
aws secretsmanager put-secret-value \
  --secret-id rally/staging/db-url \
  --secret-string "postgresql://user:pass@host:5432/rally"
```

After the RDS module applies, the DB endpoint is available in `tofu output rds_endpoint`.
