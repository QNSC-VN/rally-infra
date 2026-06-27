# Rally AWS Deployment Guide

Region: **ap-southeast-1** (Singapore) · IaC: **OpenTofu ≥ 1.9.1** · Runtime: **ECS Fargate** · CDN: **CloudFront + S3**

---

## Architecture Overview

```
Internet
  │
  ├─► Route 53 (CNAME) ──► CloudFront ──► S3 (rally-web SPA)
  │
  └─► Route 53 (CNAME) ──► ALB (HTTPS 443)
                                │
                                └─► ECS Fargate: rally-api (port 3000)
                                        │
                                        ├─► RDS PostgreSQL 17 (db.t4g.medium)
                                        ├─► ElastiCache Serverless (Valkey)
                                        ├─► SQS (notifications, audit, reporting, search)
                                        └─► SNS topic (domain-events) → SQS subscriptions

ECS Fargate: rally-worker (port 3001) — consumes SQS, never behind ALB
ECS Task: rally-develop-migrator — one-shot, run manually or from CI
```

---

## Prerequisites

### 1. Install OpenTofu ≥ 1.9.1

> **Important**: This repo requires OpenTofu, not Terraform. The two are incompatible at the state level.

```bash
# Linux / WSL — standalone installer
curl -fsSL https://get.opentofu.org/install-opentofu.sh | sh -s -- --install-method standalone

# macOS or Linux via Homebrew
brew install opentofu

# Verify — must print v1.9.x or higher
tofu --version
```

### 2. Configure AWS CLI and Credentials

```bash
# Install AWS CLI v2 (if not already installed)
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip && sudo ./aws/install

# Option A — AWS SSO (recommended)
aws configure sso
# Follow prompts: SSO start URL, SSO region, account, role name, profile name
aws sso login --profile <your-profile>
export AWS_PROFILE=<your-profile>

# Option B — Long-lived access keys (CI bootstrap only)
aws configure
# Enter: Access Key ID, Secret Access Key, default region ap-southeast-1, output json

# Verify credentials work
aws sts get-caller-identity
# Expected output:
# {
#     "UserId": "AIDAXXXXXXXXXXXXXXXXX",
#     "Account": "123456789012",
#     "Arn": "arn:aws:iam::123456789012:user/deploy-user"
# }
```

You need **AdministratorAccess** (or equivalent) for the initial bootstrap.

### 3. Note Your AWS Account ID

```bash
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "Account ID: $AWS_ACCOUNT_ID"
# Keep this value — you'll use it multiple times
```

### 4. Install Docker (for Step 7)

```bash
# Check Docker is running
docker info

# Enable BuildKit for faster multi-stage builds
export DOCKER_BUILDKIT=1
```

### 5. Install jq (for JSON parsing in scripts below)

```bash
# Debian/Ubuntu
sudo apt-get install -y jq

# macOS
brew install jq
```

---

## Step 1 — Bootstrap Remote State (one-time)

OpenTofu stores all infrastructure state in S3 and uses DynamoDB for state locking.
These resources must exist **before** running any `tofu init`.

```bash
export STATE_BUCKET="qnsc-tofu-state"
export LOCK_TABLE="qnsc-tofu-locks"
export REGION="ap-southeast-1"

# ── S3 State Bucket ───────────────────────────────────────────────────────────
# Idempotent check — skip if already exists
if aws s3 ls "s3://$STATE_BUCKET" --region $REGION 2>/dev/null; then
  echo "Bucket already exists — skipping creation"
else
  aws s3 mb s3://$STATE_BUCKET --region $REGION
fi

# Enable versioning — protects against accidental state corruption
aws s3api put-bucket-versioning \
  --bucket $STATE_BUCKET \
  --versioning-configuration Status=Enabled

# Enable AES-256 server-side encryption at rest
aws s3api put-bucket-encryption \
  --bucket $STATE_BUCKET \
  --server-side-encryption-configuration '{
    "Rules":[{
      "ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"},
      "BucketKeyEnabled":true
    }]
  }'

# Block all public access
aws s3api put-public-access-block \
  --bucket $STATE_BUCKET \
  --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

# ── DynamoDB Lock Table ───────────────────────────────────────────────────────
if aws dynamodb describe-table --table-name $LOCK_TABLE --region $REGION 2>/dev/null; then
  echo "DynamoDB table already exists — skipping"
else
  aws dynamodb create-table \
    --table-name $LOCK_TABLE \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --region $REGION
fi
```

> **Verify**: `aws s3 ls s3://qnsc-tofu-state` — bucket exists. `aws dynamodb describe-table --table-name qnsc-tofu-locks --region ap-southeast-1` — table exists.

---

## Step 2 — Request ACM Certificates

You need **two certificates** — one for the ALB (must be in ap-southeast-1) and one for CloudFront (must be in us-east-1).

> **No domain yet?** Purchase one via AWS Route 53 Domains (~$9/yr). DNS validation takes ~2–5 minutes after CNAME records are added.

### 2a. ALB certificate (ap-southeast-1)

```bash
ALB_CERT_ARN=$(aws acm request-certificate \
  --region ap-southeast-1 \
  --domain-name "api-dev.yourdomain.com" \
  --validation-method DNS \
  --query CertificateArn --output text)

echo "ALB cert ARN: $ALB_CERT_ARN"
# Save this → paste into terraform.tfvars as: acm_cert_arn
```

### 2b. CloudFront certificate (us-east-1 — REQUIRED for CloudFront)

```bash
CF_CERT_ARN=$(aws acm request-certificate \
  --region us-east-1 \
  --domain-name "app-dev.yourdomain.com" \
  --validation-method DNS \
  --query CertificateArn --output text)

echo "CloudFront cert ARN: $CF_CERT_ARN"
# Save this → paste into terraform.tfvars as: web_acm_cert_arn
```

### 2c. Get DNS validation records

```bash
# ALB cert CNAME record
aws acm describe-certificate \
  --region ap-southeast-1 \
  --certificate-arn $ALB_CERT_ARN \
  --query 'Certificate.DomainValidationOptions[*].{Name:ResourceRecord.Name,Value:ResourceRecord.Value}' \
  --output table

# CloudFront cert CNAME record
aws acm describe-certificate \
  --region us-east-1 \
  --certificate-arn $CF_CERT_ARN \
  --query 'Certificate.DomainValidationOptions[*].{Name:ResourceRecord.Name,Value:ResourceRecord.Value}' \
  --output table
```

Add the CNAME records to your DNS provider. **If using Route 53**:

```bash
ZONE_ID=$(aws route53 list-hosted-zones \
  --query "HostedZones[?Name=='yourdomain.com.'].Id" \
  --output text | sed 's|/hostedzone/||')

# Replace _CNAME_NAME_ and _CNAME_VALUE_ with values from the table above
aws route53 change-resource-record-sets \
  --hosted-zone-id $ZONE_ID \
  --change-batch '{
    "Changes": [{
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "_CNAME_NAME_",
        "Type": "CNAME",
        "TTL": 300,
        "ResourceRecords": [{"Value": "_CNAME_VALUE_"}]
      }
    }]
  }'
```

### 2d. Wait for ISSUED status

```bash
# Poll every 10s until both certs show ISSUED
watch -n 10 "aws acm describe-certificate \
  --region ap-southeast-1 --certificate-arn $ALB_CERT_ARN \
  --query 'Certificate.Status' --output text"

watch -n 10 "aws acm describe-certificate \
  --region us-east-1 --certificate-arn $CF_CERT_ARN \
  --query 'Certificate.Status' --output text"
```

---

## Step 3 — Deploy Shared Resources (ECR + IAM/OIDC)

Creates:
- **ECR repositories**: `rally-api`, `rally-worker`
- **GitHub Actions IAM roles** (OIDC — no static keys)
- **GitHub OIDC provider** in IAM (once per AWS account)

```bash
cd live/_shared

cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars:
#   github_org = "your-github-username-or-org"
#   create_oidc_provider = true   ← set false if another project already created it

tofu init
tofu plan       # review ~10–15 resources
tofu apply      # < 2 minutes
```

**Save all outputs**:

```bash
tofu output -json
```

| Output | Purpose |
|--------|---------|
| `ecr_urls["rally-api"]` | ECR URL to push/pull rally-api |
| `ecr_urls["rally-worker"]` | ECR URL to push/pull rally-worker |
| `ecr_push_role_arn` | IAM role for GitHub Actions to push Docker images |
| `deploy_role_arns["develop"]` | IAM role for GitHub Actions to deploy API to ECS |
| `infra_apply_role_arn` | IAM role for GitHub Actions to run `tofu apply` |
| `web_deploy_role_arns["develop"]` | IAM role for rally-web to deploy to S3/CloudFront |

### OIDC provider conflict

If `create_oidc_provider = true` fails because the provider already exists in this account:

```bash
# Find the existing ARN
aws iam list-open-id-connect-providers \
  --query 'OpenIDConnectProviderList[*].Arn' --output text

# In terraform.tfvars, set:
# create_oidc_provider = false
# existing_oidc_provider_arn = "arn:aws:iam::ACCOUNT_ID:oidc-provider/token.actions.githubusercontent.com"

tofu apply   # re-apply
```

---

## Step 4 — Deploy Develop Environment

Creates ~65 AWS resources including VPC, ALB, ECS cluster + services, RDS, ElastiCache, SQS/SNS, S3, CloudFront, WAF.

```bash
cd live/develop

cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars`:

```hcl
# From Step 2a — ALB cert (ap-southeast-1)
acm_cert_arn = "arn:aws:acm:ap-southeast-1:123456789012:certificate/YOUR-CERT-ID"

# From Step 2b — CloudFront cert (us-east-1)
web_acm_cert_arn = "arn:aws:acm:us-east-1:123456789012:certificate/YOUR-CERT-ID"

# Microsoft Entra (Azure AD) SSO — leave empty to disable
entra_tenant_id = ""   # e.g. "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
entra_client_id = ""   # e.g. "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
```

```bash
tofu init
tofu plan -var-file=terraform.tfvars    # review ~65 resources
tofu apply -var-file=terraform.tfvars   # takes 10–15 min (RDS + NAT are slowest)
```

**Save all outputs**:

```bash
tofu output -json > /tmp/rally-develop-outputs.json

# Extract common values into shell variables for use in Steps 5–10
export ALB_DNS=$(tofu output -raw alb_dns_name)
export RDS_ENDPOINT=$(tofu output -raw rds_endpoint)
export CACHE_ENDPOINT=$(tofu output -raw cache_endpoint)
export S3_WEB=$(tofu output -raw web_s3_bucket)
export CF_ID=$(tofu output -raw web_cloudfront_id)
export CF_URL=$(tofu output -raw web_cloudfront_url)
export SUBNET_ID=$(tofu output -json private_subnet_ids | jq -r '.[0]')
export SG_ID=$(tofu output -raw sg_app_id)
export MIGRATOR_TD=$(tofu output -raw ecs_migrator_task_def)
export ATTACHMENTS_BUCKET=$(tofu output -raw attachments_bucket)

echo "ALB:     $ALB_DNS"
echo "RDS:     $RDS_ENDPOINT"
echo "Cache:   $CACHE_ENDPOINT"
echo "Web S3:  $S3_WEB"
echo "CDN:     $CF_URL"
```

**Add DNS records** (after tofu apply):

```bash
# In your DNS provider:
#   api-dev.yourdomain.com   CNAME   <ALB_DNS>
#   app-dev.yourdomain.com   CNAME   <CloudFront domain from CF_URL>

# Route 53 example:
ZONE_ID=$(aws route53 list-hosted-zones \
  --query "HostedZones[?Name=='yourdomain.com.'].Id" \
  --output text | sed 's|/hostedzone/||')

aws route53 change-resource-record-sets --hosted-zone-id $ZONE_ID \
  --change-batch "{
    \"Changes\": [
      {\"Action\":\"UPSERT\",\"ResourceRecordSet\":{
        \"Name\":\"api-dev.yourdomain.com.\",\"Type\":\"CNAME\",\"TTL\":300,
        \"ResourceRecords\":[{\"Value\":\"$ALB_DNS\"}]
      }},
      {\"Action\":\"UPSERT\",\"ResourceRecordSet\":{
        \"Name\":\"app-dev.yourdomain.com.\",\"Type\":\"CNAME\",\"TTL\":300,
        \"ResourceRecords\":[{\"Value\":\"$(echo $CF_URL | sed 's|https://||')\"}]
      }}
    ]
  }"
```

---

## Step 5 — Fill Application Secrets in Secrets Manager

**ECS tasks will not start until all secrets have values.** The secrets module creates empty placeholders at `rally/develop/<key>`.

### 5a. Generate JWT Keys (Ed25519)

```bash
# Generate Ed25519 keypair
openssl genpkey -algorithm ed25519 -out jwt_private.pem
openssl pkey -pubout -in jwt_private.pem -out jwt_public.pem

# Store base64-encoded PEM in Secrets Manager
aws secretsmanager put-secret-value \
  --region ap-southeast-1 \
  --secret-id "rally/develop/jwt-private" \
  --secret-string "$(base64 -w0 jwt_private.pem)"

aws secretsmanager put-secret-value \
  --region ap-southeast-1 \
  --secret-id "rally/develop/jwt-public" \
  --secret-string "$(base64 -w0 jwt_public.pem)"

# Delete local key files — never commit these
rm jwt_private.pem jwt_public.pem
echo "JWT keys stored ✓"
```

### 5b. Database URL

The RDS module auto-generates a strong master password stored at `rally-develop/db-master-password` as a JSON object.

```bash
# Retrieve auto-generated master password (format: JSON with username/password/dbname)
RDS_SECRET=$(aws secretsmanager get-secret-value \
  --region ap-southeast-1 \
  --secret-id "rally-develop/db-master-password" \
  --query SecretString --output text)

DB_USER=$(echo $RDS_SECRET | jq -r '.username')   # rallyadmin
DB_PASS=$(echo $RDS_SECRET | jq -r '.password')
DB_NAME=$(echo $RDS_SECRET | jq -r '.dbname')     # rally

echo "DB user: $DB_USER, DB name: $DB_NAME"

# Store the app DATABASE_URL
# Note: rallyadmin has full DDL rights — suitable for both app + migrations
aws secretsmanager put-secret-value \
  --region ap-southeast-1 \
  --secret-id "rally/develop/db-url" \
  --secret-string "postgresql://${DB_USER}:${DB_PASS}@${RDS_ENDPOINT}:5432/${DB_NAME}?sslmode=require"

echo "DATABASE_URL stored ✓"
```

### 5c. Redis / Valkey URL

ElastiCache Serverless uses TLS. Use `rediss://` (double 's') for TLS.

```bash
aws secretsmanager put-secret-value \
  --region ap-southeast-1 \
  --secret-id "rally/develop/redis-url" \
  --secret-string "rediss://${CACHE_ENDPOINT}:6379"

echo "REDIS_URL stored ✓"
```

### 5d. CSRF Secret

```bash
CSRF_SECRET=$(openssl rand -hex 32)

aws secretsmanager put-secret-value \
  --region ap-southeast-1 \
  --secret-id "rally/develop/csrf-secret" \
  --secret-string "$CSRF_SECRET"

echo "CSRF_SECRET stored ✓"
```

### 5e. Verify all secrets are filled

```bash
for SECRET in db-url redis-url jwt-private jwt-public csrf-secret; do
  CHANGED=$(aws secretsmanager describe-secret \
    --region ap-southeast-1 \
    --secret-id "rally/develop/${SECRET}" \
    --query 'LastChangedDate' --output text 2>/dev/null)
  if [[ "$CHANGED" == "None" || -z "$CHANGED" ]]; then
    echo "❌  rally/develop/$SECRET — NOT YET FILLED"
  else
    echo "✓   rally/develop/$SECRET — filled"
  fi
done
```

---

## Step 6 — Configure GitHub Actions Secrets & Variables

Workflows use OIDC to assume IAM roles — no static AWS access keys needed.

### 6a. Repository-level Secrets (all three repos)

**GitHub → Repo → Settings → Secrets and variables → Actions → New repository secret**

| Secret | Value |
|--------|-------|
| `AWS_ACCOUNT_ID` | Your 12-digit AWS account number |

### 6b. Create GitHub Environments

In each repo (rally-api, rally-web, rally-infra):
**Settings → Environments → New environment** → name it `develop`

### 6c. rally-api — `develop` environment

**Variables** (Settings → Environments → develop → Add variable):

| Variable | Value | Source |
|----------|-------|--------|
| `AWS_REGION` | `ap-southeast-1` | Hardcoded |
| `ECR_REGISTRY` | `ACCOUNT_ID.dkr.ecr.ap-southeast-1.amazonaws.com` | `echo $AWS_ACCOUNT_ID` |
| `ECS_CLUSTER` | `rally-develop` | `tofu output -raw ecs_cluster_name` |
| `ECS_API_SERVICE` | `api` | `tofu output -raw ecs_api_service` |
| `ECS_WORKER_SERVICE` | `worker` | `tofu output -raw ecs_worker_service` |
| `ECS_MIGRATOR_TASK_DEF` | `rally-develop-migrator` | `tofu output -raw ecs_migrator_task_def` |
| `ECS_MIGRATOR_SUBNET` | `subnet-xxxxxxxx` | `tofu output -json private_subnet_ids \| jq -r '.[0]'` |
| `ECS_MIGRATOR_SG` | `sg-xxxxxxxx` | `tofu output -raw sg_app_id` |

**Secrets** (Settings → Environments → develop → Add secret):

| Secret | Value | Source |
|--------|-------|--------|
| `ECR_PUSH_ROLE_ARN` | `arn:aws:iam::ACCOUNT:role/...` | `_shared` tofu: `ecr_push_role_arn` |
| `ECS_DEPLOY_ROLE_ARN` | `arn:aws:iam::ACCOUNT:role/...` | `_shared` tofu: `deploy_role_arns["develop"]` |

### 6d. rally-web — `develop` environment

**Variables**:

| Variable | Value | Source |
|----------|-------|--------|
| `AWS_REGION` | `ap-southeast-1` | Hardcoded |
| `S3_BUCKET` | `rally-web-develop` | `tofu output -raw web_s3_bucket` |
| `CLOUDFRONT_ID` | `EXXXXXXXXXXXXXXX` | `tofu output -raw web_cloudfront_id` |
| `VITE_API_URL` | `https://api-dev.yourdomain.com` | Your API domain |
| `VITE_APP_ENV` | `development` | Hardcoded |
| `VITE_ENTRA_TENANT_ID` | `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx` | Azure Portal (or leave empty) |
| `VITE_ENTRA_CLIENT_ID` | `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx` | Azure Portal (or leave empty) |

**Secrets**:

| Secret | Value | Source |
|--------|-------|--------|
| `WEB_DEPLOY_ROLE_ARN` | `arn:aws:iam::ACCOUNT:role/...` | `_shared` tofu: `web_deploy_role_arns["develop"]` |

### 6e. rally-infra — Repository secrets

| Secret | Value |
|--------|-------|
| `INFRA_APPLY_ROLE_ARN` | `_shared` tofu: `infra_apply_role_arn` |
| `ACM_CERT_ARN_DEVELOP` | Your ap-southeast-1 ALB cert ARN (Step 2a) |
| `WEB_ACM_CERT_ARN_DEVELOP` | Your us-east-1 CloudFront cert ARN (Step 2b) |

---

## Step 7 — Build & Push Initial Docker Images

ECS tasks fail with `CannotPullContainerError` until an image exists in ECR.

```bash
cd /path/to/rally-api

export DOCKER_BUILDKIT=1

# Authenticate to ECR (token valid for 12 hours)
aws ecr get-login-password --region ap-southeast-1 | \
  docker login --username AWS --password-stdin \
  "${AWS_ACCOUNT_ID}.dkr.ecr.ap-southeast-1.amazonaws.com"

ECR_BASE="${AWS_ACCOUNT_ID}.dkr.ecr.ap-southeast-1.amazonaws.com"

# Build + push API (multi-stage target 'api')
docker build --target api --build-arg NODE_ENV=production -t rally-api:latest .
docker tag rally-api:latest ${ECR_BASE}/rally-api:latest
docker push ${ECR_BASE}/rally-api:latest
echo "rally-api pushed ✓"

# Build + push Worker (multi-stage target 'worker')
docker build --target worker --build-arg NODE_ENV=production -t rally-worker:latest .
docker tag rally-worker:latest ${ECR_BASE}/rally-worker:latest
docker push ${ECR_BASE}/rally-worker:latest
echo "rally-worker pushed ✓"

# Verify images are in ECR
aws ecr describe-images \
  --region ap-southeast-1 \
  --repository-name rally-api \
  --query 'imageDetails[*].{Tag:imageTags[0],Pushed:imagePushedAt}' \
  --output table
```

> **Dockerfile targets**: Adjust `--target` if your Dockerfile uses different stage names.

---

## Step 8 — Run Database Migrations

The migrator is a one-shot ECS task (`rally-develop-migrator`) that applies schema migrations then exits. It is never scheduled automatically.

```bash
REGION="ap-southeast-1"
CLUSTER="rally-develop"

# Pull values from tofu output (must be in live/develop directory)
cd /path/to/rally-infra/live/develop
MIGRATOR_TD=$(tofu output -raw ecs_migrator_task_def)
SUBNET_ID=$(tofu output -json private_subnet_ids | jq -r '.[0]')
SG_ID=$(tofu output -raw sg_app_id)

echo "Task def:  $MIGRATOR_TD"
echo "Subnet:    $SUBNET_ID"
echo "Sec group: $SG_ID"

# Launch the migrator task
TASK_ARN=$(aws ecs run-task \
  --region $REGION \
  --cluster $CLUSTER \
  --task-definition $MIGRATOR_TD \
  --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={
    subnets=[$SUBNET_ID],
    securityGroups=[$SG_ID],
    assignPublicIp=DISABLED
  }" \
  --query 'tasks[0].taskArn' --output text)

echo "Task launched: $TASK_ARN"

# Wait for completion (migrations typically take < 60 seconds)
aws ecs wait tasks-stopped --region $REGION --cluster $CLUSTER --tasks $TASK_ARN

# Check exit code
EXIT_CODE=$(aws ecs describe-tasks \
  --region $REGION --cluster $CLUSTER --tasks $TASK_ARN \
  --query 'tasks[0].containers[0].exitCode' --output text)

echo "Exit code: $EXIT_CODE"
[[ "$EXIT_CODE" == "0" ]] && echo "✓ Migrations succeeded" || echo "❌ Migration failed"

# Tail migration logs
aws logs tail /ecs/rally-develop/migrator \
  --region $REGION --since 10m --format short
```

### If migrations fail

```bash
# Most common causes:
# 1. rally/develop/db-url secret empty → complete Step 5b first
# 2. ECS task can't reach RDS → verify security group egress allows TCP 5432

aws ec2 describe-security-groups \
  --region ap-southeast-1 --group-ids $SG_ID \
  --query 'SecurityGroups[0].IpPermissionsEgress' --output table
```

---

## Step 9 — Force ECS Service Deployment

After images are pushed (Step 7) and secrets are filled (Step 5), force a new deployment so ECS picks up the latest image.

```bash
REGION="ap-southeast-1"
CLUSTER="rally-develop"

aws ecs update-service \
  --region $REGION --cluster $CLUSTER --service api \
  --force-new-deployment \
  --query 'service.{status:status,desired:desiredCount,running:runningCount}' \
  --output table

aws ecs update-service \
  --region $REGION --cluster $CLUSTER --service worker \
  --force-new-deployment \
  --query 'service.{status:status,desired:desiredCount,running:runningCount}' \
  --output table

# Block until both services are healthy (~2–3 min)
aws ecs wait services-stable \
  --region $REGION --cluster $CLUSTER --services api worker

echo "✓ Both services stable"
```

**Monitor logs in real time**:

```bash
aws logs tail /ecs/rally-develop/api    --follow --region ap-southeast-1 --format short
aws logs tail /ecs/rally-develop/worker --follow --region ap-southeast-1 --format short
```

**Rollback to a previous task definition revision**:

```bash
# List recent revisions
aws ecs list-task-definitions \
  --region ap-southeast-1 --family-prefix rally-develop-api \
  --sort DESC --query 'taskDefinitionArns[:5]' --output table

# Roll back to revision :3
aws ecs update-service \
  --region ap-southeast-1 --cluster rally-develop \
  --service api --task-definition rally-develop-api:3

aws ecs wait services-stable \
  --region ap-southeast-1 --cluster rally-develop --services api
```

---

## Step 10 — Deploy the Frontend (rally-web)

```bash
cd /path/to/rally-web

# Set all build-time VITE_ variables
export VITE_API_URL="https://api-dev.yourdomain.com"
export VITE_APP_ENV="development"
export VITE_ENTRA_TENANT_ID=""   # Azure tenant ID, or leave empty
export VITE_ENTRA_CLIENT_ID=""   # Azure app client ID, or leave empty

# Install and build
pnpm install --frozen-lockfile
pnpm build
# Output: dist/

# Get S3 and CloudFront values from infra
cd /path/to/rally-infra/live/develop
S3_BUCKET=$(tofu output -raw web_s3_bucket)
CF_ID=$(tofu output -raw web_cloudfront_id)
cd /path/to/rally-web

# Sync hashed assets with long-lived cache (1 year, immutable)
aws s3 sync dist/ s3://${S3_BUCKET}/ \
  --delete \
  --exclude "index.html" \
  --cache-control "public, max-age=31536000, immutable" \
  --region ap-southeast-1

# index.html must be no-cache so users always get the latest entry point
aws s3 cp dist/index.html s3://${S3_BUCKET}/index.html \
  --cache-control "no-cache, no-store, must-revalidate" \
  --content-type "text/html" \
  --region ap-southeast-1

# Invalidate CloudFront cache so edge nodes serve new index.html immediately
INVALIDATION_ID=$(aws cloudfront create-invalidation \
  --distribution-id $CF_ID --paths "/*" \
  --query 'Invalidation.Id' --output text)

echo "Invalidation started: $INVALIDATION_ID"

# Wait for completion (~30–60 seconds)
aws cloudfront wait invalidation-completed \
  --distribution-id $CF_ID --id $INVALIDATION_ID

echo "✓ CloudFront cache cleared"
```

---

## Step 11 — Verify the Deployment

### 11a. ECS service health

```bash
aws ecs describe-services \
  --region ap-southeast-1 --cluster rally-develop \
  --services api worker \
  --query 'services[*].{
    Service:serviceName,
    Status:status,
    Desired:desiredCount,
    Running:runningCount,
    LastEvent:events[0].message
  }' --output table
# Expected: Status=ACTIVE, Desired=Running=1, Pending=0
```

### 11b. API health check

```bash
# Via ALB DNS directly
ALB_DNS=$(cd /path/to/rally-infra/live/develop && tofu output -raw alb_dns_name)
curl -sf "https://${ALB_DNS}/v1/healthz" | jq .
# Expected: {"status":"ok","db":"ok","cache":"ok","timestamp":"..."}

# Via custom domain (after DNS propagation)
curl -sf "https://api-dev.yourdomain.com/v1/healthz" | jq .
```

### 11c. Web app check

```bash
CF_URL=$(cd /path/to/rally-infra/live/develop && tofu output -raw web_cloudfront_url)
curl -sf "$CF_URL" | grep -i "<title>"
# Expected: <title>Rally</title>
```

### 11d. API login smoke test

```bash
API_URL="https://api-dev.yourdomain.com"

TOKEN=$(curl -sf -X POST "${API_URL}/v1/auth/login" \
  -H "Content-Type: application/json" \
  -d '{"email":"admin@acme.dev","password":"Admin@Rally2026!"}' \
  | jq -r '.accessToken')

echo "Token: ${TOKEN:0:30}..."

curl -sf "${API_URL}/v1/workspaces" \
  -H "Authorization: Bearer $TOKEN" \
  | jq '.[] | {id,name}'
```

### 11e. Queue health check

```bash
for Q in notifications audit reporting search; do
  URL=$(aws sqs get-queue-url \
    --region ap-southeast-1 --queue-name "rally-develop-${Q}" \
    --query QueueUrl --output text)
  COUNT=$(aws sqs get-queue-attributes \
    --region ap-southeast-1 --queue-url $URL \
    --attribute-names ApproximateNumberOfMessages \
    --query 'Attributes.ApproximateNumberOfMessages' --output text)
  echo "rally-develop-${Q}: ${COUNT} messages"
done
```

---

## CI/CD — Ongoing Deploys via GitHub Actions

| Trigger | What happens |
|---------|-------------|
| Push to `main` on **rally-api** | Build images → push to ECR → run migrator task → redeploy API + Worker |
| Push to `main` on **rally-web** | Build with VITE vars → sync to S3 → invalidate CloudFront |
| Push to `main` on **rally-infra** | `tofu apply` on `_shared` then `live/develop` |
| Tag `v*.*.*` on **rally-api** | Same pipeline → **production** (requires manual approval gate) |

---

## Troubleshooting

### ECS tasks fail to start

```bash
# Find the most recent stopped task and read its error
TASK=$(aws ecs list-tasks \
  --region ap-southeast-1 --cluster rally-develop \
  --family rally-develop-api --desired-status STOPPED \
  --query 'taskArns[0]' --output text)

aws ecs describe-tasks \
  --region ap-southeast-1 --cluster rally-develop --tasks $TASK \
  --query 'tasks[0].{Reason:stoppedReason,Containers:containers[*].{Name:name,Exit:exitCode,Reason:reason}}' \
  --output json
```

| Error message | Cause | Fix |
|---------------|-------|-----|
| `ResourceInitializationError: unable to retrieve secrets` | Secret value is still empty | Complete Step 5 |
| `CannotPullContainerError` | No image in ECR | Run Step 7 |
| `connection refused` or `ECONNREFUSED` in logs | Wrong DB or cache URL | Check Step 5b / 5c |

### CloudWatch Logs

```bash
aws logs tail /ecs/rally-develop/api    --follow --region ap-southeast-1 --format short
aws logs tail /ecs/rally-develop/worker --follow --region ap-southeast-1 --format short

# Search for errors
aws logs filter-log-events \
  --region ap-southeast-1 \
  --log-group-name /ecs/rally-develop/api \
  --filter-pattern "ERROR" \
  --query 'events[*].message' --output text | tail -20
```

### Scale down (save costs when not in use)

```bash
aws ecs update-service --region ap-southeast-1 --cluster rally-develop \
  --service api --desired-count 0
aws ecs update-service --region ap-southeast-1 --cluster rally-develop \
  --service worker --desired-count 0
```

### Scale back up

```bash
aws ecs update-service --region ap-southeast-1 --cluster rally-develop \
  --service api --desired-count 1
aws ecs update-service --region ap-southeast-1 --cluster rally-develop \
  --service worker --desired-count 1
aws ecs wait services-stable --region ap-southeast-1 \
  --cluster rally-develop --services api worker
```

---

## Cost Estimate (develop, ap-southeast-1)

| Service | Spec | Est. USD/month |
|---------|------|---------------|
| ECS Fargate — api | 0.5 vCPU / 1 GB, 1 task | ~$15 |
| ECS Fargate — worker | 0.25 vCPU / 0.5 GB, 1 task | ~$8 |
| RDS PostgreSQL 17 | db.t4g.medium, 20 GB gp3 | ~$45 |
| ElastiCache Serverless | 2 GB max, 2000 eCPU/s | ~$10 |
| ALB | 1 LCU/hr baseline | ~$20 |
| CloudFront | PriceClass_200, low traffic | ~$5 |
| NAT Gateway | Single AZ | ~$35 |
| S3 (state + web + attachments) | < 5 GB | ~$1 |
| Secrets Manager | 5 secrets | ~$3 |
| WAF | Baseline rules | ~$6 |
| SQS + SNS | Low traffic | ~$1 |
| **Total** | | **~$149/month** |

> Tip: Scale services to 0 overnight to cut ~$700/year in compute costs.
