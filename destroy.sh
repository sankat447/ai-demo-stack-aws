#!/usr/bin/env bash
# =============================================================================
#  AI Demo Stack on AWS — Complete Teardown
#
#  Usage   : ./destroy.sh
#  WARNING : Destroys ALL resources — OCP cluster, AWS infra, data
#  Duration: ~25-30 minutes
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/scripts/common.sh"

LOG_FILE="${LOG_DIR}/destroy_${TIMESTAMP}.log"

# ── Warning Banner ──────────────────────────────────────────────────────────
echo ""
echo -e "${RED}${BOLD}╔══════════════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${RED}${BOLD}║                    COMPLETE TEARDOWN WARNING                        ║${RESET}"
echo -e "${RED}${BOLD}╚══════════════════════════════════════════════════════════════════════╝${RESET}"
echo ""
echo -e "${RED}This will PERMANENTLY DESTROY all resources:${RESET}"
echo ""
echo -e "${YELLOW}OCP Cluster:${RESET}"
echo "   - OpenShift 4.20 cluster (all namespaces and workloads)"
echo "   - Control plane (3 masters) and all worker nodes"
echo "   - ArgoCD, operators, and all deployed applications"
echo ""
echo -e "${YELLOW}AWS Platform:${RESET}"
echo "   - Aurora PostgreSQL cluster (ALL DATA WILL BE LOST)"
echo "   - EFS file system (all notebook files)"
echo "   - S3 data lake bucket (will be emptied)"
echo "   - ECR repositories (all container images)"
echo "   - Lambda scheduler and EventBridge rules"
echo "   - VPC, subnets, NAT gateway, security groups"
echo "   - IAM roles and policies"
echo "   - SSM parameters, budget alerts"
echo ""
echo -e "${RED}${BOLD}THIS ACTION CANNOT BE UNDONE${RESET}"
echo ""
read -rp "Type 'destroy-demo' to confirm complete teardown: " confirm

if [[ "${confirm}" != "destroy-demo" ]]; then
  echo -e "${YELLOW}Teardown cancelled — no changes made${RESET}"
  exit 0
fi

log "Starting teardown — log: ${LOG_FILE}"

# =============================================================================
section "PHASE 1 — AUTHENTICATION"
# =============================================================================

aws_sso_login
redhat_sso_login

# =============================================================================
section "PHASE 2 — DELETE ARGOCD APPLICATIONS"
# =============================================================================

KUBECONFIG_PATH="${ENV_DIR}/ocp-install-dir/${CLUSTER_NAME}/auth/kubeconfig"
if [[ -f "$KUBECONFIG_PATH" ]]; then
  export KUBECONFIG="$KUBECONFIG_PATH"

  if oc whoami &>/dev/null 2>&1; then
    log_info "Cleaning up ArgoCD applications..."

    # Delete app-of-apps first
    oc delete application --all -n openshift-gitops --wait=false 2>/dev/null || true
    log_ok "ArgoCD applications deletion initiated"

    # Wait for apps to be removed
    sleep 30

    # Force-remove finalizers if stuck
    for app in $(oc get applications.argoproj.io -n openshift-gitops -o name 2>/dev/null); do
      oc patch "$app" -n openshift-gitops --type merge -p '{"metadata":{"finalizers":null}}' 2>/dev/null || true
    done
    log_ok "ArgoCD cleanup complete"
  else
    log_warn "Cannot connect to OCP — cluster may already be destroyed"
  fi
else
  log_warn "No kubeconfig found — skipping ArgoCD cleanup"
fi

# =============================================================================
section "PHASE 3 — DESTROY OCP CLUSTER"
# =============================================================================

INSTALL_DIR="${ENV_DIR}/ocp-install-dir/${CLUSTER_NAME}"
if [[ -d "$INSTALL_DIR" ]]; then
  log_info "Destroying OCP cluster..."
  openshift-install destroy cluster --dir="$INSTALL_DIR" --log-level=info 2>&1 | tee -a "${LOG_FILE}" || true
  log_ok "OCP cluster destruction complete"
else
  log_warn "No OCP install directory found at ${INSTALL_DIR} — skipping cluster destroy"
fi

# =============================================================================
section "PHASE 4 — TERRAFORM DESTROY"
# =============================================================================

cd "$ENV_DIR" || abort "Cannot navigate to ${ENV_DIR}"

DESTROY_LOG="${LOG_DIR}/tf-destroy_${TIMESTAMP}.log"
log_info "Running: terraform destroy -auto-approve"

terraform init -reconfigure 2>&1 | tee -a "${LOG_FILE}" || true

terraform destroy -auto-approve 2>&1 | tee "$DESTROY_LOG"
TF_DESTROY_RC=${PIPESTATUS[0]}

if [[ $TF_DESTROY_RC -eq 0 ]]; then
  log_ok "terraform destroy succeeded"
else
  log_fail "terraform destroy failed — see: ${DESTROY_LOG}"

  # Retry once after re-auth
  log_warn "Retrying after re-authentication..."
  aws_sso_login
  terraform destroy -auto-approve 2>&1 | tee "$DESTROY_LOG"
  if [[ ${PIPESTATUS[0]} -eq 0 ]]; then
    log_ok "terraform destroy succeeded on retry"
  else
    log_fail "terraform destroy failed on retry"
  fi
fi

# =============================================================================
section "PHASE 5 — VERIFY CLEANUP"
# =============================================================================

log_info "Verifying resource cleanup..."

# Check S3 bucket
BUCKET_NAME="rhoai-demo-demo-data-lake"
if aws s3api head-bucket --bucket "$BUCKET_NAME" --profile "$AWS_PROFILE" 2>/dev/null; then
  log_warn "S3 bucket ${BUCKET_NAME} still exists"
else
  log_ok "S3 bucket cleaned up"
fi

# Check VPC
VPC_COUNT=$(aws ec2 describe-vpcs --filters "Name=tag:Project,Values=rhoai-demo" --profile "$AWS_PROFILE" --query 'Vpcs | length(@)' --output text 2>/dev/null || echo "0")
if [[ "$VPC_COUNT" -gt 0 ]]; then
  log_warn "VPC(s) still exist with Project=rhoai-demo tag"
else
  log_ok "VPC cleaned up"
fi

# Check RDS
RDS_COUNT=$(aws rds describe-db-clusters --profile "$AWS_PROFILE" --query "DBClusters[?contains(DBClusterIdentifier, 'rhoai-demo')] | length(@)" --output text 2>/dev/null || echo "0")
if [[ "$RDS_COUNT" -gt 0 ]]; then
  log_warn "Aurora cluster(s) still exist"
else
  log_ok "Aurora cleaned up"
fi

log_ok "Cleanup verification complete"

# =============================================================================
section "TEARDOWN COMPLETE"
# =============================================================================

echo ""
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${GREEN}${BOLD}║                  TEARDOWN COMPLETE                                  ║${RESET}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════════════════════╝${RESET}"
echo ""

print_summary
