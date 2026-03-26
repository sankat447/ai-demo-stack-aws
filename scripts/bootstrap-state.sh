#!/usr/bin/env bash
# =============================================================================
#  Bootstrap Terraform State Backend (run once per AWS account)
#  Creates S3 bucket + DynamoDB table for state locking
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

LOG_FILE="${LOG_DIR}/bootstrap-state_${TIMESTAMP}.log"

section "BOOTSTRAP: Terraform State Backend"

aws_sso_login

ACCOUNT_ID=$(aws sts get-caller-identity --profile "$AWS_PROFILE" --query Account --output text)
BUCKET_NAME="ai-demo-stack-tfstate"
TABLE_NAME="ai-demo-stack-tflock"

log_info "Account: ${ACCOUNT_ID}"
log_info "Bucket:  ${BUCKET_NAME}"
log_info "Table:   ${TABLE_NAME}"

# ── Create S3 bucket ────────────────────────────────────────────────────────
if aws s3api head-bucket --bucket "$BUCKET_NAME" --profile "$AWS_PROFILE" 2>/dev/null; then
  log_ok "S3 bucket already exists: ${BUCKET_NAME}"
else
  aws s3api create-bucket \
    --bucket "$BUCKET_NAME" \
    --region "$AWS_REGION" \
    --profile "$AWS_PROFILE" 2>&1 | tee -a "${LOG_FILE}"
  log_ok "S3 bucket created: ${BUCKET_NAME}"
fi

# Enable versioning
aws s3api put-bucket-versioning \
  --bucket "$BUCKET_NAME" \
  --versioning-configuration Status=Enabled \
  --profile "$AWS_PROFILE" 2>/dev/null
log_ok "Versioning enabled"

# Enable encryption
aws s3api put-bucket-encryption \
  --bucket "$BUCKET_NAME" \
  --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}' \
  --profile "$AWS_PROFILE" 2>/dev/null
log_ok "Encryption enabled"

# Block public access
aws s3api put-public-access-block \
  --bucket "$BUCKET_NAME" \
  --public-access-block-configuration "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true" \
  --profile "$AWS_PROFILE" 2>/dev/null
log_ok "Public access blocked"

# ── Create DynamoDB table ───────────────────────────────────────────────────
if aws dynamodb describe-table --table-name "$TABLE_NAME" --profile "$AWS_PROFILE" &>/dev/null; then
  log_ok "DynamoDB table already exists: ${TABLE_NAME}"
else
  aws dynamodb create-table \
    --table-name "$TABLE_NAME" \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --region "$AWS_REGION" \
    --profile "$AWS_PROFILE" 2>&1 | tee -a "${LOG_FILE}"
  log_ok "DynamoDB table created: ${TABLE_NAME}"
fi

echo ""
log_ok "State backend ready. Update environments/demo/backend.tf with:"
echo -e "     ${DIM}bucket         = \"${BUCKET_NAME}\"${RESET}"
echo -e "     ${DIM}dynamodb_table = \"${TABLE_NAME}\"${RESET}"
echo ""

print_summary
