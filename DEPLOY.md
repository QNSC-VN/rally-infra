# Rally AWS Deployment Guide

Region: **ap-southeast-1** (Singapore) · IaC: **OpenTofu** · Runtime: **ECS Fargate** · CDN: **CloudFront + S3**

---

## Architecture Overview

```
Internet → Route 53 → CloudFront (rally-web SPA) → S3 bucket
                    → ALB (HTTPS 443) → ECS Fargate (rally-api) → RDS PostgreSQL 17
                                                                 → ElastiCache Valkey
                                                                 → SQS / SNS
```

---

## Prerequisites

### 1. Install OpenTofu 1.9.1

```bash
# Linux / WSL
curl -fsSL https://get.opentofu.org/install-opentofu.sh | sh -s -- --install-method standalone

# Or via Homebrew (macOS / Linux)
brew install opentofu

# Verify
tofu --version   # should print OpenTofu v1.9.1
```

### 2. Configure AWS Credentials

```bash
# Option A — AWS SSO (recommended for daily use)
aws configure sso
aws sso login --profile your-profile
export AWS_PROFILE=your-profile

# Option B — Long-lived access keys (CI/CD bootstrap only, rotate afterwards)
aws configure
# Paste: Access Key ID, Secret Access Key, region ap-southeast-1, output json

# Verify
aws sts get-caller-identity
# Should print: Account, UserId, Arn
```

You need **AdministratorAccess** (or equivalent) for the initial bootstrap.

### 3. Note Your AWS Account ID

```bash
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo $AWS_ACCOUNT_ID
```

---

## Step 1 — Bootstrap Remote State (one-time)

OpenTofu stores state in S3 and uses DynamoDB for locking.

```bash
# Create the S3 state bucket
aws s3 mb s3://qncs-tofu-state --region ap-southeast-1

# Enable versioning (protects against accidental state corruption)
aws s3api put-bucket-versioning \
  --bucket qncs-tofu-state \
  --versioning-configuration Status=Enabled

# Enable server-side encryption
aws s3api put-bucket-encryption \
  --bucket qncs-tofu-state \
  --server-side-encryption-configuration '{
    "Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]
  }'

# Block public access
aws s3api put-public-access-block \
  --bucket qncs-tofu-state \
  --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

# Create DynamoDB lock table
aws dynamodb create-table \
  --table-name qncs-tofu-locks \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region ap-southeast-1
```

---

## Step 2 — Request ACM Certificates

You need **two** certificates. You can request them now and validate via DNS (takes ~5 minutes).

> If you don't have a domain yet, you can use a placeholder domain and validate via email,
> or skip HTTPS temporarily and provide a self-signed cert ARN workaround.
> **Recommended**: request real certs — ALB and CloudFront require ACM certs.

### 2a. ALB certificate (ap-southeast-1)

```bash
aws acm request-certificate \
  --region ap-southeast-1 \
  --domain-name api-dev.yourdomain.com \
  --validation-method DNS \
  --query CertificateArn --output text
# Save the ARN → ACM_CERT_ARN_DEVELOP
```

### 2b. CloudFront certificate (us-east-1 — REQUIRED by CloudFront)

```bash
aws acm request-certificate \
  --region us-east-1 \
  --domain-name app-dev.yourdomain.com \
  --validation-method DNS \
  --query CertificateArn --output text
# Save the ARN → WEB_ACM_CERT_ARN_DEVELOP
```

### Validate both certificates

```bash
# Check status until it shows ISSUED
aws acm describe-certificate \
  --region ap-southeast-1 \
  --certificate-arn <ACM_CERT_ARN_DEVELOP> \
  --query 'Certificate.Status' --output text

aws acm describe-certificate \
  --region us-east-1 \
  --certificate-arn <WEB_ACM_CERT_ARN_DEVELOP> \
  --query 'Certificate.Status' --output text
```

Add the CNAME records shown in the ACM console to your DNS provider, then wait for `ISSUED`.

---

## Step 3 — Deploy Shared Resources (ECR + IAM/OIDC)

This creates ECR repositories and all GitHub Actions IAM roles.

```bash
cd live/_shared

# Copy and edit variables
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars:
#   github_org = "your-actual-github-username-or-org"
#   create_oidc_provider = true   (set false if GitHub OIDC already exists in this account)

tofu init
tofu plan    # review the plan — should show ECR repos + IAM roles
tofu apply   # type 'yes' to confirm
```

**Save the outputs** — you'll need them for GitHub Actions secrets:

```bash
tofu output -json
# Notable outputs:
#   ecr_urls.rally-api       → ECR registry URL for rally-api
#   ecr_urls.rally-worker    → ECR registry URL for rally-worker
#   ecr_push_role_arn        → ARN for GitHub Actions to push images
#   deploy_role_arns.develop → ARN for GitHub Actions to deploy to develop
#   infra_apply_role_arn     → ARN for GitHub Actions to run tofu apply
#   web_deploy_role_arns.develop → ARN for rally-web to deploy to S3/CloudFront
```

---

## Step 4 — Deploy Develop Environment

```bash
cd live/develop

# Copy and edit variables
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars — set acm_cert_arn and web_acm_cert_arn from Step 2

tofu init
tofu plan -var-file=terraform.tfvars    # review — should show ~60+ resources
tofu apply -var-file=terraform.tfvars   # type 'yes' to confirm (~10-15 min)
```

**Save the outputs**:

```bash
tofu output -json
# Notable:
#   alb_dns_name          → ALB DNS (add to your api-dev CNAME)
#   rds_endpoint          → RDS host (needed for DATABASE_URL secret)
#   cache_endpoint        → Valkey/Redis host (needed for REDIS_URL secret)
#   secret_arns           → Map of secret ARNs to fill in Secrets Manager
#   web_s3_bucket         → S3 bucket name (e.g. rally-web-develop)
#   web_cloudfront_id     → CloudFront distribution ID
#   web_cloudfront_url    → https://xxxxx.cloudfront.net (public URL)
```

---

## Step 5 — Fill Application Secrets in Secrets Manager

ECS tasks will fail to start until secrets have values. Fill each one:

### 5a. Generate JWT keys (Ed25519)

```bash
# Generate private key
openssl genpkey -algorithm ed25519 -out jwt_private.pem
# Derive public key
openssl pkey -pubout -in jwt_private.pem -out jwt_public.pem

# Store as base64-encoded PEM
aws secretsmanager put-secret-value \
  --region ap-southeast-1 \
  --secret-id rally/develop/jwt-private \
  --secret-string "$(base64 -w0 jwt_private.pem)"

aws secretsmanager put-secret-value \
  --region ap-southeast-1 \
  --secret-id rally/develop/jwt-public \
  --secret-string "$(base64 -w0 jwt_public.pem)"

# Clean up local key files
rm jwt_private.pem jwt_public.pem
```

### 5b. Database URL

```bash
# Get the RDS endpoint from tofu output
RDS_ENDPOINT=$(cd live/develop && tofu output -raw rds_endpoint)

# The RDS module stores the auto-generated password in Secrets Manager.
# Retrieve it:
DB_PASS=$(aws secretsmanager get-secret-value \
  --region ap-southeast-1 \
  --secret-id rally-develop-db-password \
  --query SecretString --output text | jq -r '.password // .')

aws secretsmanager put-secret-value \
  --region ap-southeast-1 \
  --secret-id rally/develop/db-url \
  --secret-string "postgresql://rally:${DB_PASS}@${RDS_ENDPOINT}:5432/rally"
```

### 5c. Redis URL

```bash
CACHE_ENDPOINT=$(cd live/develop && tofu output -raw cache_endpoint)

aws secretsmanager put-secret-value \
  --region ap-southeast-1 \
  --secret-id rally/develop/redis-url \
  --secret-string "rediss://${CACHE_ENDPOINT}:6379"
```

### 5d. CSRF Secret

```bash
CSRF_SECRET=$(openssl rand -hex 32)

aws secretsmanager put-secret-value \
  --region ap-southeast-1 \
  --secret-id rally/develop/csrf-secret \
  --secret-string "$CSRF_SECRET"
```

---

## Step 6 — Configure GitHub Actions Secrets & Variables

In your GitHub repository settings (rally-api, rally-web, rally-infra):

### Repository-level Secrets (all three repos)

| Secret | Value |
|--------|-------|
| `AWS_ACCOUNT_ID` | Your 12-digit AWS account number |
| `AWS_REGION` | `ap-southeast-1` |

### GitHub Environments

Go to **Settings → Environments** in each repo and create `develop` and `production`.

#### rally-api — `develop` environment variables

| Variable | Value (from `tofu output`) |
|----------|---------------------------|
| `ECS_CLUSTER` | `rally-develop` |
| `ECS_API_SERVICE` | `api` |
| `ECS_WORKER_SERVICE` | `worker` |
| `ECS_MIGRATOR_TASK_DEF` | `rally-develop-migrator` |
| `ECS_MIGRATOR_SUBNET` | First private subnet ID (from `tofu output`) |
| `ECS_MIGRATOR_SG` | App security group ID (from `tofu output`) |

#### rally-infra — GitHub Secrets

| Secret | Value (from `tofu output -json` on `_shared`) |
|--------|----------------------------------------------|
| `ACM_CERT_ARN_DEVELOP` | Your ap-southeast-1 ALB cert ARN |
| `ACM_CERT_ARN_PROD` | Your prod ALB cert ARN (later) |

#### rally-web — `develop` environment variables

| Variable | Value |
|----------|-------|
| `S3_BUCKET` | `rally-web-develop` |
| `CLOUDFRONT_ID` | CloudFront distribution ID from `tofu output` |
| `VITE_API_BASE_URL` | `https://api-dev.yourdomain.com` |

---

## Step 7 — Build & Push Initial Docker Images

Before ECS services can start, ECR needs at least one image tagged `:latest`.

```bash
cd /path/to/rally-api

# Authenticate Docker to ECR
aws ecr get-login-password --region ap-southeast-1 | \
  docker login --username AWS --password-stdin \
  ${AWS_ACCOUNT_ID}.dkr.ecr.ap-southeast-1.amazonaws.com

ECR_BASE="${AWS_ACCOUNT_ID}.dkr.ecr.ap-southeast-1.amazonaws.com"

# Build and push API image
docker build --target api -t rally-api:latest .
docker tag rally-api:latest ${ECR_BASE}/rally-api:latest
docker push ${ECR_BASE}/rally-api:latest

# Build and push Worker image
docker build --target worker -t rally-worker:latest .
docker tag rally-worker:latest ${ECR_BASE}/rally-worker:latest
docker push ${ECR_BASE}/rally-worker:latest

# Build and push Migrator image
docker build --target migrator -t rally-migrator:latest .
docker tag rally-migrator:latest ${ECR_BASE}/rally-migrator:latest
docker push ${ECR_BASE}/rally-migrator:latest
```

---

## Step 8 — Run Database Migrations

Run the migrator ECS task (one-shot) to create the schema:

```bash
# Get values from tofu output
CLUSTER="rally-develop"
TASK_DEF="rally-develop-migrator"
SUBNET_ID="<private-subnet-id>"    # from tofu output
SG_ID="<app-security-group-id>"   # from tofu output

aws ecs run-task \
  --region ap-southeast-1 \
  --cluster $CLUSTER \
  --task-definition $TASK_DEF \
  --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[$SUBNET_ID],securityGroups=[$SG_ID],assignPublicIp=DISABLED}"

# Watch logs
aws logs tail /ecs/rally-develop/migrator --follow --region ap-southeast-1
```

---

## Step 9 — Force ECS Service Deployment

After pushing images and filling secrets, force a new deployment:

```bash
aws ecs update-service \
  --region ap-southeast-1 \
  --cluster rally-develop \
  --service api \
  --force-new-deployment

aws ecs update-service \
  --region ap-southeast-1 \
  --cluster rally-develop \
  --service worker \
  --force-new-deployment

# Watch until stable
aws ecs wait services-stable \
  --region ap-southeast-1 \
  --cluster rally-develop \
  --services api worker
```

---

## Step 10 — Deploy the Frontend (rally-web)

```bash
cd /path/to/rally-web

# Set the API base URL for the build
export VITE_API_BASE_URL="https://api-dev.yourdomain.com"

# Build
pnpm install --frozen-lockfile
pnpm build

# Sync to S3
aws s3 sync dist/ s3://rally-web-develop/ \
  --delete \
  --cache-control "public, max-age=31536000, immutable" \
  --exclude "index.html"

# index.html must be no-cache so users always get the latest
aws s3 cp dist/index.html s3://rally-web-develop/index.html \
  --cache-control "no-cache, no-store, must-revalidate" \
  --content-type "text/html"

# Invalidate CloudFront cache
CF_ID=$(cd /path/to/rally-infra/live/develop && tofu output -raw web_cloudfront_id)
aws cloudfront create-invalidation \
  --distribution-id $CF_ID \
  --paths "/*"
```

---

## Step 11 — Verify the Deployment

```bash
# 1. Check ECS services are running
aws ecs describe-services \
  --region ap-southeast-1 \
  --cluster rally-develop \
  --services api worker \
  --query 'services[*].{name:serviceName,running:runningCount,desired:desiredCount,status:status}'

# 2. Check API health through the ALB
ALB_DNS=$(cd /path/to/rally-infra/live/develop && tofu output -raw alb_dns_name)
curl -k https://${ALB_DNS}/v1/healthz
# Expected: {"status":"ok",...}

# 3. Check API via your domain (after DNS propagation)
curl https://api-dev.yourdomain.com/v1/healthz

# 4. Access the web app
echo "Web URL: $(cd /path/to/rally-infra/live/develop && tofu output -raw web_cloudfront_url)"
```

---

## CI/CD — Ongoing Deploys via GitHub Actions

Once all secrets/variables are configured (Step 6), deploys are fully automated:

| Action | What happens |
|--------|-------------|
| Push to `main` on **rally-api** | Builds images → pushes to ECR → runs migrations → deploys to develop ECS |
| Push to `main` on **rally-web** | Builds frontend → syncs to S3 → invalidates CloudFront |
| Push to `main` on **rally-infra** | `tofu apply` on `_shared` then `develop` |
| Push tag `v*.*.*` on **rally-api** | Same as above but targets `production` (requires approval gate) |

---

## Troubleshooting

### ECS tasks failing to start

```bash
# Check stopped task reason
aws ecs describe-tasks \
  --region ap-southeast-1 \
  --cluster rally-develop \
  --tasks $(aws ecs list-tasks --cluster rally-develop --query 'taskArns[0]' --output text) \
  --query 'tasks[0].stoppedReason'

# Check CloudWatch logs
aws logs tail /ecs/rally-develop/api --follow --region ap-southeast-1
```

Common causes:
- Secrets not yet filled → `ResourceInitializationError: unable to retrieve secrets`
- Wrong DATABASE_URL → connection refused at boot
- Missing ECR image → `CannotPullContainerError`

### Secrets Manager permission error

Ensure the ECS task execution role has `secretsmanager:GetSecretValue` permission.
The `ecs-service` module grants this automatically via `secret_arns`.

### `tofu apply` fails on first `_shared` apply

If `create_oidc_provider = true` and a GitHub OIDC provider already exists in your account
(e.g. from another project), you'll get a conflict error. In that case:

```bash
# Get the existing provider ARN
aws iam list-open-id-connect-providers --query 'OpenIDConnectProviderList[*].Arn'

# Then in live/_shared/terraform.tfvars:
create_oidc_provider = false
existing_oidc_provider_arn = "arn:aws:iam::ACCOUNT:oidc-provider/token.actions.githubusercontent.com"
```

---

## Cost Estimate (develop environment, ap-southeast-1)

| Service | Spec | Est. USD/month |
|---------|------|---------------|
| ECS Fargate (api) | 0.5 vCPU / 1 GB, 1 task | ~$15 |
| ECS Fargate (worker) | 0.25 vCPU / 0.5 GB, 1 task | ~$8 |
| RDS PostgreSQL | db.t4g.medium, 20 GB | ~$45 |
| ElastiCache Serverless | 2 GB max, 2K eCPU/s | ~$10 |
| ALB | 1 LCU/hr baseline | ~$20 |
| CloudFront | PriceClass_200, low traffic | ~$5 |
| NAT Gateway | Single AZ | ~$35 |
| Secrets Manager | 5 secrets | ~$3 |
| **Total** | | **~$141/month** |

To reduce costs during development: scale ECS services to 0 when not in use:
```bash
aws ecs update-service --cluster rally-develop --service api --desired-count 0
aws ecs update-service --cluster rally-develop --service worker --desired-count 0
```
