#!/usr/bin/env bash
# =============================================================================
#  AI Demo Stack — Post-Deployment Quality Check
#  Validates all AWS infrastructure, OCP cluster, and GitOps deployments
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

LOG_FILE="${LOG_DIR}/quality-check_${TIMESTAMP}.log"

echo ""
echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${CYAN}${BOLD}║              AI DEMO STACK — QUALITY CHECK                          ║${RESET}"
echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════════════════════════════════╝${RESET}"
echo ""

# =============================================================================
section "CHECK 1: AWS INFRASTRUCTURE"
# =============================================================================

# ── VPC ─────────────────────────────────────────────────────────────────────
VPC_ID=$(aws ec2 describe-vpcs --filters "Name=tag:Project,Values=ai" --profile "$AWS_PROFILE" --query 'Vpcs[0].VpcId' --output text 2>/dev/null || echo "None")
if [[ "$VPC_ID" != "None" && -n "$VPC_ID" ]]; then
  VPC_CIDR=$(aws ec2 describe-vpcs --vpc-ids "$VPC_ID" --profile "$AWS_PROFILE" --query 'Vpcs[0].CidrBlock' --output text 2>/dev/null)
  log_ok "VPC: ${VPC_ID} (${VPC_CIDR})"
else
  log_fail "VPC not found"
fi

# ── Subnets ─────────────────────────────────────────────────────────────────
if [[ "$VPC_ID" != "None" ]]; then
  SUBNET_COUNT=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=${VPC_ID}" --profile "$AWS_PROFILE" --query 'Subnets | length(@)' --output text 2>/dev/null || echo "0")
  if [[ "$SUBNET_COUNT" -ge 4 ]]; then
    log_ok "Subnets: ${SUBNET_COUNT} (expected 4: 2 public + 2 private)"
  else
    log_warn "Subnets: ${SUBNET_COUNT} (expected 4)"
  fi
fi

# ── NAT Gateway ─────────────────────────────────────────────────────────────
NAT_STATE=$(aws ec2 describe-nat-gateways --filter "Name=tag:Project,Values=ai" --profile "$AWS_PROFILE" --query 'NatGateways[0].State' --output text 2>/dev/null || echo "None")
if [[ "$NAT_STATE" == "available" ]]; then
  log_ok "NAT Gateway: available"
else
  log_warn "NAT Gateway: ${NAT_STATE}"
fi

# ── Aurora ──────────────────────────────────────────────────────────────────
AURORA_STATUS=$(aws rds describe-db-clusters --profile "$AWS_PROFILE" --query "DBClusters[?contains(DBClusterIdentifier, 'ai-demo')].Status" --output text 2>/dev/null || echo "None")
if [[ "$AURORA_STATUS" == "available" ]]; then
  AURORA_ENDPOINT=$(aws rds describe-db-clusters --profile "$AWS_PROFILE" --query "DBClusters[?contains(DBClusterIdentifier, 'ai-demo')].Endpoint" --output text 2>/dev/null)
  log_ok "Aurora PostgreSQL: available (${AURORA_ENDPOINT})"
else
  log_warn "Aurora PostgreSQL: ${AURORA_STATUS}"
fi

# ── EFS ─────────────────────────────────────────────────────────────────────
EFS_COUNT=$(aws efs describe-file-systems --profile "$AWS_PROFILE" --query "FileSystems[?contains(Name, 'ai-demo')] | length(@)" --output text 2>/dev/null || echo "0")
if [[ "$EFS_COUNT" -gt 0 ]]; then
  log_ok "EFS: ${EFS_COUNT} file system(s)"
else
  log_warn "EFS: not found"
fi

# ── S3 ──────────────────────────────────────────────────────────────────────
if aws s3api head-bucket --bucket "ai-demo-data-lake" --profile "$AWS_PROFILE" 2>/dev/null; then
  FOLDER_COUNT=$(aws s3 ls s3://ai-demo-data-lake/ --profile "$AWS_PROFILE" 2>/dev/null | wc -l | tr -d ' ')
  log_ok "S3 data lake: exists (${FOLDER_COUNT} top-level items)"
else
  log_warn "S3 data lake: not found"
fi

# ── ECR ─────────────────────────────────────────────────────────────────────
ECR_COUNT=$(aws ecr describe-repositories --profile "$AWS_PROFILE" --query "repositories[?contains(repositoryName, 'ai-demo')] | length(@)" --output text 2>/dev/null || echo "0")
if [[ "$ECR_COUNT" -ge 3 ]]; then
  log_ok "ECR repositories: ${ECR_COUNT}"
else
  log_warn "ECR repositories: ${ECR_COUNT} (expected 3)"
fi

# ── Lambda ──────────────────────────────────────────────────────────────────
LAMBDA_STATE=$(aws lambda get-function --function-name "ai-demo-ocp-scheduler" --profile "$AWS_PROFILE" --query 'Configuration.State' --output text 2>/dev/null || echo "None")
if [[ "$LAMBDA_STATE" == "Active" ]]; then
  log_ok "Lambda scheduler: Active"
else
  log_warn "Lambda scheduler: ${LAMBDA_STATE}"
fi

# ── IAM Roles ───────────────────────────────────────────────────────────────
for ROLE in s3-access bedrock-access ecr-access ssm-access; do
  if aws iam get-role --role-name "ai-demo-${ROLE}" --profile "$AWS_PROFILE" &>/dev/null; then
    log_ok "IAM role: ai-demo-${ROLE}"
  else
    log_warn "IAM role: ai-demo-${ROLE} not found"
  fi
done

# =============================================================================
section "CHECK 2: OCP CLUSTER"
# =============================================================================

KUBECONFIG_PATH="${ENV_DIR}/ocp-install-dir/${CLUSTER_NAME}/auth/kubeconfig"
if [[ -f "$KUBECONFIG_PATH" ]]; then
  export KUBECONFIG="$KUBECONFIG_PATH"

  if oc whoami &>/dev/null 2>&1; then
    log_ok "OCP connected as: $(oc whoami)"

    # Cluster version
    CV_STATUS=$(oc get clusterversion version -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "Unknown")
    CV_VER=$(oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null || echo "Unknown")
    if [[ "$CV_STATUS" == "True" ]]; then
      log_ok "Cluster version: ${CV_VER} (Available=True)"
    else
      log_warn "Cluster version: ${CV_VER} (Available=${CV_STATUS})"
    fi

    # Cluster operators
    DEGRADED_OPS=$(oc get clusteroperators -o jsonpath='{range .items[*]}{.metadata.name}{" "}{range .status.conditions[*]}{.type}={.status}{" "}{end}{"\n"}{end}' 2>/dev/null | grep "Degraded=True" | awk '{print $1}' || echo "")
    if [[ -z "$DEGRADED_OPS" ]]; then
      log_ok "All ClusterOperators healthy"
    else
      log_warn "Degraded operators: ${DEGRADED_OPS}"
    fi

    # Nodes
    NODE_COUNT=$(oc get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
    READY_COUNT=$(oc get nodes --no-headers 2>/dev/null | grep -c " Ready " || echo "0")
    log_ok "Nodes: ${READY_COUNT}/${NODE_COUNT} Ready"

    # Storage classes
    for SC in gp3-csi efs-sc; do
      if oc get storageclass "$SC" &>/dev/null 2>&1; then
        log_ok "StorageClass: ${SC}"
      else
        log_warn "StorageClass: ${SC} not found"
      fi
    done
  else
    log_warn "Cannot connect to OCP cluster"
  fi
else
  log_warn "No kubeconfig found — skipping OCP checks"
fi

# =============================================================================
section "CHECK 3: GITOPS / ARGOCD"
# =============================================================================

if [[ -f "$KUBECONFIG_PATH" ]] && oc whoami &>/dev/null 2>&1; then
  export KUBECONFIG="$KUBECONFIG_PATH"

  # ArgoCD running
  ARGOCD_READY=$(oc get deployment openshift-gitops-server -n openshift-gitops -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  if [[ "$ARGOCD_READY" -gt 0 ]]; then
    log_ok "ArgoCD server: running (${ARGOCD_READY} replicas)"
  else
    log_warn "ArgoCD server: not ready"
  fi

  # Application sync status
  TOTAL_APPS=$(oc get applications.argoproj.io -n openshift-gitops --no-headers 2>/dev/null | wc -l | tr -d ' ')
  SYNCED_APPS=$(oc get applications.argoproj.io -n openshift-gitops -o jsonpath='{range .items[*]}{.status.sync.status}{"\n"}{end}' 2>/dev/null | grep -c "Synced" || echo "0")
  HEALTHY_APPS=$(oc get applications.argoproj.io -n openshift-gitops -o jsonpath='{range .items[*]}{.status.health.status}{"\n"}{end}' 2>/dev/null | grep -c "Healthy" || echo "0")

  log_ok "ArgoCD apps: ${SYNCED_APPS}/${TOTAL_APPS} synced, ${HEALTHY_APPS}/${TOTAL_APPS} healthy"

  # List out-of-sync apps
  OOSYNC=$(oc get applications.argoproj.io -n openshift-gitops -o jsonpath='{range .items[*]}{.metadata.name}={.status.sync.status}{"\n"}{end}' 2>/dev/null | grep -v "Synced" || echo "")
  if [[ -n "$OOSYNC" ]]; then
    log_warn "Out-of-sync apps:"
    echo "$OOSYNC" | while read -r line; do
      echo -e "     ${YELLOW}${line}${RESET}"
    done
  fi

  # Operator CSVs
  INSTALLED_CSVS=$(oc get csv --all-namespaces -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.phase}{"\n"}{end}' 2>/dev/null | grep -c "Succeeded" || echo "0")
  log_ok "Operator CSVs: ${INSTALLED_CSVS} succeeded"
fi

# =============================================================================
section "CHECK 4: APPLICATIONS"
# =============================================================================

if [[ -f "$KUBECONFIG_PATH" ]] && oc whoami &>/dev/null 2>&1; then
  export KUBECONFIG="$KUBECONFIG_PATH"

  NAMESPACES=("ai-demo" "rhoai-mlflow" "rhoai-minio" "rhoai-monitoring" "rhoai-tools" "rhoai-sso" "vault" "langchain")

  for NS in "${NAMESPACES[@]}"; do
    if oc get namespace "$NS" &>/dev/null 2>&1; then
      RUNNING=$(oc get pods -n "$NS" --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ')
      TOTAL=$(oc get pods -n "$NS" --no-headers 2>/dev/null | wc -l | tr -d ' ')
      if [[ "$TOTAL" -gt 0 ]]; then
        log_ok "${NS}: ${RUNNING}/${TOTAL} pods running"
      else
        log_warn "${NS}: no pods"
      fi
    fi
  done

  # Check routes
  echo ""
  log_info "Application Routes:"
  for NS in ai-demo rhoai-minio rhoai-mlflow rhoai-monitoring rhoai-sso rhoai-tools vault langchain; do
    ROUTES=$(oc get routes -n "$NS" -o jsonpath='{range .items[*]}  {.metadata.name}: https://{.spec.host}{"\n"}{end}' 2>/dev/null || echo "")
    if [[ -n "$ROUTES" ]]; then
      echo "$ROUTES"
    fi
  done
fi

# =============================================================================
section "QUALITY CHECK COMPLETE"
# =============================================================================

print_summary
