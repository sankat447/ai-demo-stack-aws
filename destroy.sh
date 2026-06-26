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
section "PHASE 2.5 — DESTROY AURORA + EFS (must precede OCP destroy)"
# =============================================================================
# Aurora and EFS live in the OCP-installed VPC (lesson #1). If we run
# openshift-install destroy first, the installer enters an infinite NAT
# gateway delete loop because Aurora ENIs and EFS mount target ENIs in the
# OCP VPC subnets prevent the NAT GWs from fully terminating. Destroy these
# TF-managed resources first so the OCP VPC is empty of TF-side dependencies
# before openshift-install gets its hands on it.

cd "$ENV_DIR" || abort "Cannot navigate to ${ENV_DIR}"

# Step 1: Terraform-managed Aurora/EFS (the normal case).
if AWS_PROFILE="$AWS_PROFILE" terraform state list 2>/dev/null | grep -qE "^module\.aurora|^module\.efs"; then
  log_info "Destroying Aurora + EFS before OCP cluster..."
  TF_PRE_DESTROY_LOG="${LOG_DIR}/pre_destroy_${TIMESTAMP}.log"
  # Include null_resource.efs_storage_class — its dependency on module.efs.file_system_id
  # blocks a clean -target destroy if omitted (observed 2026-05-26).
  AWS_PROFILE="$AWS_PROFILE" terraform destroy \
    -target=module.aurora -target=module.efs \
    -target=aws_security_group.aurora_ocp -target=aws_security_group.efs_ocp \
    -target=null_resource.efs_storage_class \
    -auto-approve 2>&1 | tee "$TF_PRE_DESTROY_LOG"
  if [[ ${PIPESTATUS[0]} -eq 0 ]]; then
    log_ok "Aurora + EFS destroyed (TF-managed)"
  else
    log_warn "Aurora/EFS TF pre-destroy had errors — see: $TF_PRE_DESTROY_LOG"
  fi
else
  log_info "No Aurora/EFS in TF state — checking AWS for orphans..."
fi

# Step 2: AWS-direct fallback — catches orphans where TF state was wiped or
# resources were created outside terraform. Lesson from 2026-06-26: Phase 2.5
# said "no Aurora in state — skipping" but Aurora was still alive in AWS,
# blocking openshift-install destroy via the RDS ENI.
PROJECT_PREFIX="${PROJECT_NAME:-ai}-${ENVIRONMENT:-demo}"

# Aurora orphans
ORPHAN_AURORA=$(aws rds describe-db-clusters --profile "$AWS_PROFILE" \
  --query "DBClusters[?starts_with(DBClusterIdentifier,'${PROJECT_PREFIX}')].DBClusterIdentifier" \
  --output text 2>/dev/null || true)
for AURORA_ID in $ORPHAN_AURORA; do
  log_warn "Orphan Aurora cluster found: ${AURORA_ID} — deleting"
  # Delete instances first
  for INST in $(aws rds describe-db-instances --profile "$AWS_PROFILE" \
        --filters "Name=db-cluster-id,Values=${AURORA_ID}" \
        --query 'DBInstances[*].DBInstanceIdentifier' --output text 2>/dev/null); do
    aws rds delete-db-instance --db-instance-identifier "$INST" \
      --skip-final-snapshot --profile "$AWS_PROFILE" \
      --query 'DBInstance.DBInstanceStatus' --output text 2>&1 || true
  done
  # Wait until instances are gone (RDS doesn't allow cluster delete with live instances)
  log_info "Waiting for Aurora instances to drain (up to 10 min)..."
  for _ in $(seq 1 60); do
    COUNT=$(aws rds describe-db-instances --profile "$AWS_PROFILE" \
      --filters "Name=db-cluster-id,Values=${AURORA_ID}" \
      --query 'length(DBInstances)' --output text 2>/dev/null || echo 0)
    [[ "$COUNT" == "0" ]] && break
    sleep 10
  done
  aws rds delete-db-cluster --db-cluster-identifier "$AURORA_ID" \
    --skip-final-snapshot --profile "$AWS_PROFILE" \
    --query 'DBCluster.Status' --output text 2>&1 || true
  log_ok "Aurora ${AURORA_ID} deletion initiated"
done

# EFS orphans — match by Name tag prefix
ORPHAN_EFS=$(aws efs describe-file-systems --profile "$AWS_PROFILE" \
  --query "FileSystems[?Name && starts_with(Name,'${PROJECT_PREFIX}')].FileSystemId" \
  --output text 2>/dev/null || true)
for FS_ID in $ORPHAN_EFS; do
  log_warn "Orphan EFS found: ${FS_ID} — deleting"
  # Delete access points first
  for AP in $(aws efs describe-access-points --file-system-id "$FS_ID" \
        --profile "$AWS_PROFILE" --query 'AccessPoints[*].AccessPointId' --output text 2>/dev/null); do
    aws efs delete-access-point --access-point-id "$AP" --profile "$AWS_PROFILE" 2>&1 || true
  done
  # Delete mount targets (these hold ENIs that block VPC cleanup)
  for MT in $(aws efs describe-mount-targets --file-system-id "$FS_ID" \
        --profile "$AWS_PROFILE" --query 'MountTargets[*].MountTargetId' --output text 2>/dev/null); do
    aws efs delete-mount-target --mount-target-id "$MT" --profile "$AWS_PROFILE" 2>&1 || true
  done
  # Wait for mount targets to be gone before deleting file system
  for _ in $(seq 1 30); do
    COUNT=$(aws efs describe-mount-targets --file-system-id "$FS_ID" \
      --profile "$AWS_PROFILE" --query 'length(MountTargets)' --output text 2>/dev/null || echo 0)
    [[ "$COUNT" == "0" ]] && break
    sleep 10
  done
  aws efs delete-file-system --file-system-id "$FS_ID" --profile "$AWS_PROFILE" 2>&1 || true
  log_ok "EFS ${FS_ID} deletion initiated"
done

# =============================================================================
section "PHASE 3 — DESTROY OCP CLUSTER"
# =============================================================================

INSTALL_DIR="${ENV_DIR}/ocp-install-dir/${CLUSTER_NAME}"
OCP_DESTROY_FAILED=false
# openshift-install needs both the dir AND metadata.json. If a prior partial
# teardown removed metadata.json, the installer aborts with a fatal error
# ("failed while preparing to destroy cluster: ... metadata.json: no such file")
# and our set -euo pipefail kills the rest of the script. Detect this and skip
# cleanly so Phases 4-9 can still sweep TF / AWS state.
if [[ -d "$INSTALL_DIR" && -f "$INSTALL_DIR/metadata.json" ]]; then
  log_info "Destroying OCP cluster..."

  # Resolve AWS credentials for openshift-install (same logic as ocp-ipi module)
  OCP_AWS_KEY=$(grep -s 'ocp_aws_access_key_id' "${ENV_DIR}/terraform.tfvars" | awk -F'"' '{print $2}' || true)
  OCP_AWS_SECRET=$(grep -s 'ocp_aws_secret_access_key' "${ENV_DIR}/terraform.tfvars" | awk -F'"' '{print $2}' || true)
  if [[ -n "$OCP_AWS_KEY" ]]; then
    export AWS_ACCESS_KEY_ID="$OCP_AWS_KEY"
    export AWS_SECRET_ACCESS_KEY="$OCP_AWS_SECRET"
    unset AWS_SESSION_TOKEN 2>/dev/null || true
  else
    eval "$(aws configure export-credentials --profile "${AWS_PROFILE}" --format env 2>/dev/null)" || true
  fi
  export AWS_DEFAULT_REGION="${AWS_REGION}"

  openshift-install destroy cluster --dir="$INSTALL_DIR" --log-level=info 2>&1 | tee -a "${LOG_FILE}" || true
  OCP_DESTROY_RC=${PIPESTATUS[0]}

  # Restore profile-based auth for remaining phases
  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN 2>/dev/null || true

  if [[ $OCP_DESTROY_RC -eq 0 ]]; then
    log_ok "OCP cluster destruction complete"
  else
    log_fail "openshift-install destroy failed (exit code: $OCP_DESTROY_RC)"
    OCP_DESTROY_FAILED=true
    log_warn "Will attempt orphaned resource cleanup in Phase 4a"
  fi
elif [[ -d "$INSTALL_DIR" ]]; then
  log_warn "Install dir exists but metadata.json is missing — cluster already destroyed in a prior run. Skipping Phase 3."
else
  log_warn "No OCP install directory found at ${INSTALL_DIR} — skipping cluster destroy"
fi

# =============================================================================
section "PHASE 4 — PRE-DESTROY CLEANUP (cross-VPC / orphaned resources)"
# =============================================================================

cd "$ENV_DIR" || abort "Cannot navigate to ${ENV_DIR}"

# ── 4a: Clean up EFS mount targets in wrong VPC ──────────────────────────────
# The Terraform VPC and the OCP IPI VPC are separate. If EFS mount targets were
# created in the OCP VPC (by a prior deploy), they block both terraform destroy
# and new mount target creation. Detect and remove them.

log_info "Checking for EFS cross-VPC mount target conflicts..."

TF_VPC_ID=$(aws ec2 describe-vpcs \
  --filters "Name=tag:Name,Values=${CLUSTER_NAME}-*-vpc" "Name=tag:ManagedBy,Values=terraform" \
  --profile "$AWS_PROFILE" --region "$AWS_REGION" \
  --query 'Vpcs[0].VpcId' --output text 2>/dev/null || echo "None")

# Find EFS file systems tagged with our project
EFS_IDS=$(aws efs describe-file-systems \
  --profile "$AWS_PROFILE" --region "$AWS_REGION" \
  --query "FileSystems[?Tags[?Key=='Name' && contains(Value, '${CLUSTER_NAME}')]].FileSystemId" \
  --output text 2>/dev/null || echo "")

for FS_ID in $EFS_IDS; do
  # Get all mount targets for this EFS
  MT_JSON=$(aws efs describe-mount-targets --file-system-id "$FS_ID" \
    --profile "$AWS_PROFILE" --region "$AWS_REGION" --output json 2>/dev/null || echo '{"MountTargets":[]}')

  MT_COUNT=$(echo "$MT_JSON" | jq '.MountTargets | length')
  if [[ "$MT_COUNT" -eq 0 ]]; then
    continue
  fi

  for MT in $(echo "$MT_JSON" | jq -c '.MountTargets[]'); do
    MT_VPC=$(echo "$MT" | jq -r '.VpcId')
    MT_ID=$(echo "$MT" | jq -r '.MountTargetId')

    # Delete mount targets that are NOT in the Terraform-managed VPC, or all
    # mount targets if we're doing a full teardown
    if [[ "$MT_VPC" != "$TF_VPC_ID" ]] || [[ "$TF_VPC_ID" == "None" ]]; then
      log_info "Deleting orphaned EFS mount target ${MT_ID} in VPC ${MT_VPC}..."
      aws efs delete-mount-target --mount-target-id "$MT_ID" \
        --profile "$AWS_PROFILE" --region "$AWS_REGION" 2>&1 || true
    fi
  done
done

# Wait for EFS mount targets to finish deleting (ENIs need time to release)
if [[ -n "$EFS_IDS" ]]; then
  log_info "Waiting for EFS mount target ENIs to release..."
  sleep 30
fi

# ── 4b: Detect orphaned OCP VPCs ─────────────────────────────────────────────
# openshift-install creates VPCs named <infra-id>-vpc. If destroy failed or was
# skipped, these remain. Collect them for cleanup after terraform destroy.

log_info "Scanning for orphaned OCP-created VPCs..."

# Get the infrastructure ID from the install directory if available
INFRA_ID=""
if [[ -f "${INSTALL_DIR}/infrastructure-id" ]]; then
  INFRA_ID=$(cat "${INSTALL_DIR}/infrastructure-id" 2>/dev/null || true)
fi

# Find all VPCs matching the cluster name pattern that are NOT the Terraform VPC
ORPHAN_VPCS=$(aws ec2 describe-vpcs \
  --filters "Name=tag:Name,Values=*${CLUSTER_NAME}*-vpc" \
  --profile "$AWS_PROFILE" --region "$AWS_REGION" \
  --query "Vpcs[?VpcId!='${TF_VPC_ID}'].VpcId" --output text 2>/dev/null || echo "")

if [[ -n "$ORPHAN_VPCS" && "$ORPHAN_VPCS" != "None" ]]; then
  log_warn "Found orphaned VPC(s): ${ORPHAN_VPCS}"
else
  log_ok "No orphaned OCP VPCs found"
fi

# =============================================================================
section "PHASE 5 — TERRAFORM DESTROY"
# =============================================================================

DESTROY_LOG="${LOG_DIR}/tf-destroy_${TIMESTAMP}.log"
log_info "Running: terraform destroy -auto-approve"

terraform init -reconfigure 2>&1 | tee -a "${LOG_FILE}" || true

terraform destroy -auto-approve 2>&1 | tee "$DESTROY_LOG"
TF_DESTROY_RC=${PIPESTATUS[0]}

# Lesson 2026-06-26: after OCP VPC is destroyed, `data "aws_vpc" "ocp"` can't
# resolve at refresh time and terraform aborts with "no matching EC2 VPC found",
# blocking destroy of OTHER state entries (TF VPC, S3, ECR, Lambda...).
# Retry with -refresh=false to bypass.
if [[ $TF_DESTROY_RC -ne 0 ]] && grep -q "no matching EC2 VPC found" "$DESTROY_LOG" 2>/dev/null; then
  log_warn "data.aws_vpc.ocp refresh failed (OCP VPC already gone) — retrying with -refresh=false"
  terraform destroy -refresh=false -auto-approve 2>&1 | tee "$DESTROY_LOG"
  TF_DESTROY_RC=${PIPESTATUS[0]}
fi

if [[ $TF_DESTROY_RC -eq 0 ]]; then
  log_ok "terraform destroy succeeded"
else
  log_fail "terraform destroy failed — see: ${DESTROY_LOG}"

  # Retry once after re-auth
  log_warn "Retrying after re-authentication..."
  aws_sso_login
  terraform destroy -refresh=false -auto-approve 2>&1 | tee "$DESTROY_LOG"
  if [[ ${PIPESTATUS[0]} -eq 0 ]]; then
    log_ok "terraform destroy succeeded on retry"
  else
    log_fail "terraform destroy failed on retry — will attempt manual cleanup"
  fi
fi

# =============================================================================
section "PHASE 6 — ORPHANED VPC CLEANUP"
# =============================================================================

# ── Helper: delete all resources in a VPC ─────────────────────────────────────
cleanup_vpc() {
  local VPC_ID="$1"
  local VPC_NAME
  VPC_NAME=$(aws ec2 describe-vpcs --vpc-ids "$VPC_ID" \
    --profile "$AWS_PROFILE" --region "$AWS_REGION" \
    --query 'Vpcs[0].Tags[?Key==`Name`].Value | [0]' --output text 2>/dev/null || echo "$VPC_ID")

  log_info "Cleaning up VPC: ${VPC_NAME} (${VPC_ID})..."

  # 1. Delete EFS mount targets in this VPC
  for FS_ID in $(aws efs describe-file-systems --profile "$AWS_PROFILE" --region "$AWS_REGION" \
    --query 'FileSystems[].FileSystemId' --output text 2>/dev/null || echo ""); do
    for MT_ID in $(aws efs describe-mount-targets --file-system-id "$FS_ID" \
      --profile "$AWS_PROFILE" --region "$AWS_REGION" \
      --query "MountTargets[?VpcId=='${VPC_ID}'].MountTargetId" --output text 2>/dev/null || echo ""); do
      log_info "  Deleting EFS mount target ${MT_ID}..."
      aws efs delete-mount-target --mount-target-id "$MT_ID" \
        --profile "$AWS_PROFILE" --region "$AWS_REGION" 2>/dev/null || true
    done
  done

  # 2. Delete RDS instances in this VPC
  for DB_ID in $(aws rds describe-db-instances --profile "$AWS_PROFILE" --region "$AWS_REGION" \
    --output json 2>/dev/null | jq -r ".DBInstances[] | select(.DBSubnetGroup.VpcId==\"${VPC_ID}\") | .DBInstanceIdentifier" || echo ""); do
    log_info "  Deleting RDS instance ${DB_ID}..."
    aws rds delete-db-instance --db-instance-identifier "$DB_ID" --skip-final-snapshot \
      --profile "$AWS_PROFILE" --region "$AWS_REGION" 2>/dev/null || true
  done

  # 3. Delete RDS clusters in this VPC
  for CLUSTER_ID in $(aws rds describe-db-clusters --profile "$AWS_PROFILE" --region "$AWS_REGION" \
    --output json 2>/dev/null | jq -r ".DBClusters[] | select(.VpcId==\"${VPC_ID}\") | .DBClusterIdentifier" || echo ""); do
    log_info "  Deleting RDS cluster ${CLUSTER_ID}..."
    aws rds delete-db-cluster --db-cluster-identifier "$CLUSTER_ID" --skip-final-snapshot \
      --profile "$AWS_PROFILE" --region "$AWS_REGION" 2>/dev/null || true
  done

  # Wait for RDS deletions
  for DB_ID in $(aws rds describe-db-instances --profile "$AWS_PROFILE" --region "$AWS_REGION" \
    --output json 2>/dev/null | jq -r ".DBInstances[] | select(.DBSubnetGroup.VpcId==\"${VPC_ID}\") | .DBInstanceIdentifier" || echo ""); do
    log_info "  Waiting for RDS instance ${DB_ID} to delete..."
    aws rds wait db-instance-deleted --db-instance-identifier "$DB_ID" \
      --profile "$AWS_PROFILE" --region "$AWS_REGION" 2>/dev/null || true
  done

  # 4. Delete RDS subnet groups in this VPC
  for SG_NAME in $(aws rds describe-db-subnet-groups --profile "$AWS_PROFILE" --region "$AWS_REGION" \
    --output json 2>/dev/null | jq -r ".DBSubnetGroups[] | select(.VpcId==\"${VPC_ID}\") | .DBSubnetGroupName" || echo ""); do
    log_info "  Deleting RDS subnet group ${SG_NAME}..."
    aws rds delete-db-subnet-group --db-subnet-group-name "$SG_NAME" \
      --profile "$AWS_PROFILE" --region "$AWS_REGION" 2>/dev/null || true
  done

  # 5. Delete NLBs / ALBs
  for LB_ARN in $(aws elbv2 describe-load-balancers --profile "$AWS_PROFILE" --region "$AWS_REGION" \
    --output json 2>/dev/null | jq -r ".LoadBalancers[] | select(.VpcId==\"${VPC_ID}\") | .LoadBalancerArn" || echo ""); do
    log_info "  Deleting load balancer $(basename "$LB_ARN")..."
    aws elbv2 delete-load-balancer --load-balancer-arn "$LB_ARN" \
      --profile "$AWS_PROFILE" --region "$AWS_REGION" 2>/dev/null || true
  done

  # 6. Delete Classic ELBs
  for CLB_NAME in $(aws elb describe-load-balancers --profile "$AWS_PROFILE" --region "$AWS_REGION" \
    --output json 2>/dev/null | jq -r ".LoadBalancerDescriptions[] | select(.VPCId==\"${VPC_ID}\") | .LoadBalancerName" || echo ""); do
    log_info "  Deleting classic LB ${CLB_NAME}..."
    aws elb delete-load-balancer --load-balancer-name "$CLB_NAME" \
      --profile "$AWS_PROFILE" --region "$AWS_REGION" 2>/dev/null || true
  done

  # Wait for LB ENIs to detach
  sleep 30

  # 7. Delete NAT Gateways
  for NGW_ID in $(aws ec2 describe-nat-gateways \
    --filter "Name=vpc-id,Values=${VPC_ID}" "Name=state,Values=available,pending" \
    --profile "$AWS_PROFILE" --region "$AWS_REGION" \
    --query 'NatGateways[].NatGatewayId' --output text 2>/dev/null || echo ""); do
    log_info "  Deleting NAT gateway ${NGW_ID}..."
    aws ec2 delete-nat-gateway --nat-gateway-id "$NGW_ID" \
      --profile "$AWS_PROFILE" --region "$AWS_REGION" 2>/dev/null || true
  done

  # Wait for NAT gateways to delete (they take ~1-2 min)
  log_info "  Waiting for NAT gateways to delete..."
  local MAX_WAIT=180
  local ELAPSED=0
  while [[ $ELAPSED -lt $MAX_WAIT ]]; do
    local ACTIVE_NGWS
    ACTIVE_NGWS=$(aws ec2 describe-nat-gateways \
      --filter "Name=vpc-id,Values=${VPC_ID}" "Name=state,Values=available,pending,deleting" \
      --profile "$AWS_PROFILE" --region "$AWS_REGION" \
      --query 'NatGateways | length(@)' --output text 2>/dev/null || echo "0")
    if [[ "$ACTIVE_NGWS" -eq 0 ]]; then
      break
    fi
    sleep 15
    ELAPSED=$((ELAPSED + 15))
  done

  # 8. Release Elastic IPs that were attached to this VPC's NAT gateways
  # Find unattached EIPs (the NAT gateway deletion releases the association)
  for ALLOC_ID in $(aws ec2 describe-addresses --profile "$AWS_PROFILE" --region "$AWS_REGION" \
    --query 'Addresses[?AssociationId==null].AllocationId' --output text 2>/dev/null || echo ""); do
    log_info "  Releasing EIP ${ALLOC_ID}..."
    aws ec2 release-address --allocation-id "$ALLOC_ID" \
      --profile "$AWS_PROFILE" --region "$AWS_REGION" 2>/dev/null || true
  done

  # 9. Delete VPC Endpoints
  for VPCE_ID in $(aws ec2 describe-vpc-endpoints \
    --filters "Name=vpc-id,Values=${VPC_ID}" \
    --profile "$AWS_PROFILE" --region "$AWS_REGION" \
    --query 'VpcEndpoints[].VpcEndpointId' --output text 2>/dev/null || echo ""); do
    log_info "  Deleting VPC endpoint ${VPCE_ID}..."
    aws ec2 delete-vpc-endpoints --vpc-endpoint-ids "$VPCE_ID" \
      --profile "$AWS_PROFILE" --region "$AWS_REGION" 2>/dev/null || true
  done

  # 10. Detach and delete remaining ENIs
  for ENI_ID in $(aws ec2 describe-network-interfaces \
    --filters "Name=vpc-id,Values=${VPC_ID}" \
    --profile "$AWS_PROFILE" --region "$AWS_REGION" \
    --query 'NetworkInterfaces[].NetworkInterfaceId' --output text 2>/dev/null || echo ""); do
    local ATTACH_ID
    ATTACH_ID=$(aws ec2 describe-network-interfaces --network-interface-ids "$ENI_ID" \
      --profile "$AWS_PROFILE" --region "$AWS_REGION" \
      --query 'NetworkInterfaces[0].Attachment.AttachmentId' --output text 2>/dev/null || echo "None")
    if [[ "$ATTACH_ID" != "None" && -n "$ATTACH_ID" ]]; then
      aws ec2 detach-network-interface --attachment-id "$ATTACH_ID" --force \
        --profile "$AWS_PROFILE" --region "$AWS_REGION" 2>/dev/null || true
    fi
  done
  sleep 10

  for ENI_ID in $(aws ec2 describe-network-interfaces \
    --filters "Name=vpc-id,Values=${VPC_ID}" \
    --profile "$AWS_PROFILE" --region "$AWS_REGION" \
    --query 'NetworkInterfaces[].NetworkInterfaceId' --output text 2>/dev/null || echo ""); do
    aws ec2 delete-network-interface --network-interface-id "$ENI_ID" \
      --profile "$AWS_PROFILE" --region "$AWS_REGION" 2>/dev/null || true
  done

  # 11. Detach and delete Internet Gateway
  for IGW_ID in $(aws ec2 describe-internet-gateways \
    --filters "Name=attachment.vpc-id,Values=${VPC_ID}" \
    --profile "$AWS_PROFILE" --region "$AWS_REGION" \
    --query 'InternetGateways[].InternetGatewayId' --output text 2>/dev/null || echo ""); do
    log_info "  Detaching and deleting IGW ${IGW_ID}..."
    aws ec2 detach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID" \
      --profile "$AWS_PROFILE" --region "$AWS_REGION" 2>/dev/null || true
    aws ec2 delete-internet-gateway --internet-gateway-id "$IGW_ID" \
      --profile "$AWS_PROFILE" --region "$AWS_REGION" 2>/dev/null || true
  done

  # 12. Delete non-default security groups
  for SG_ID in $(aws ec2 describe-security-groups \
    --filters "Name=vpc-id,Values=${VPC_ID}" \
    --profile "$AWS_PROFILE" --region "$AWS_REGION" \
    --query "SecurityGroups[?GroupName!='default'].GroupId" --output text 2>/dev/null || echo ""); do
    log_info "  Deleting security group ${SG_ID}..."
    # Remove all ingress/egress rules first (clears cross-SG references)
    aws ec2 revoke-security-group-ingress --group-id "$SG_ID" \
      --ip-permissions "$(aws ec2 describe-security-groups --group-ids "$SG_ID" \
        --profile "$AWS_PROFILE" --region "$AWS_REGION" \
        --query 'SecurityGroups[0].IpPermissions' --output json 2>/dev/null)" \
      --profile "$AWS_PROFILE" --region "$AWS_REGION" 2>/dev/null || true
    aws ec2 revoke-security-group-egress --group-id "$SG_ID" \
      --ip-permissions "$(aws ec2 describe-security-groups --group-ids "$SG_ID" \
        --profile "$AWS_PROFILE" --region "$AWS_REGION" \
        --query 'SecurityGroups[0].IpPermissionsEgress' --output json 2>/dev/null)" \
      --profile "$AWS_PROFILE" --region "$AWS_REGION" 2>/dev/null || true
  done
  # Now delete them (two passes — first pass may fail on cross-references)
  for PASS in 1 2; do
    for SG_ID in $(aws ec2 describe-security-groups \
      --filters "Name=vpc-id,Values=${VPC_ID}" \
      --profile "$AWS_PROFILE" --region "$AWS_REGION" \
      --query "SecurityGroups[?GroupName!='default'].GroupId" --output text 2>/dev/null || echo ""); do
      aws ec2 delete-security-group --group-id "$SG_ID" \
        --profile "$AWS_PROFILE" --region "$AWS_REGION" 2>/dev/null || true
    done
  done

  # 13. Delete subnets
  for SUBNET_ID in $(aws ec2 describe-subnets \
    --filters "Name=vpc-id,Values=${VPC_ID}" \
    --profile "$AWS_PROFILE" --region "$AWS_REGION" \
    --query 'Subnets[].SubnetId' --output text 2>/dev/null || echo ""); do
    log_info "  Deleting subnet ${SUBNET_ID}..."
    aws ec2 delete-subnet --subnet-id "$SUBNET_ID" \
      --profile "$AWS_PROFILE" --region "$AWS_REGION" 2>/dev/null || true
  done

  # 14. Delete non-main route tables
  for RT_ID in $(aws ec2 describe-route-tables \
    --filters "Name=vpc-id,Values=${VPC_ID}" \
    --profile "$AWS_PROFILE" --region "$AWS_REGION" \
    --output json 2>/dev/null | jq -r '.RouteTables[] | select(.Associations[0].Main != true) | .RouteTableId' || echo ""); do
    # Disassociate first
    for ASSOC_ID in $(aws ec2 describe-route-tables --route-table-ids "$RT_ID" \
      --profile "$AWS_PROFILE" --region "$AWS_REGION" \
      --query 'RouteTables[0].Associations[?!Main].RouteTableAssociationId' --output text 2>/dev/null || echo ""); do
      aws ec2 disassociate-route-table --association-id "$ASSOC_ID" \
        --profile "$AWS_PROFILE" --region "$AWS_REGION" 2>/dev/null || true
    done
    log_info "  Deleting route table ${RT_ID}..."
    aws ec2 delete-route-table --route-table-id "$RT_ID" \
      --profile "$AWS_PROFILE" --region "$AWS_REGION" 2>/dev/null || true
  done

  # 15. Delete the VPC
  log_info "  Deleting VPC ${VPC_ID}..."
  if aws ec2 delete-vpc --vpc-id "$VPC_ID" --profile "$AWS_PROFILE" --region "$AWS_REGION" 2>&1; then
    log_ok "VPC ${VPC_NAME} (${VPC_ID}) deleted"
  else
    log_fail "Failed to delete VPC ${VPC_ID} — may have remaining dependencies"
  fi
}

# ── Clean up orphaned OCP VPCs found in Phase 4 ──────────────────────────────
# Also re-scan in case terraform destroy left behind any tagged VPCs

ALL_REMAINING_VPCS=$(aws ec2 describe-vpcs \
  --filters "Name=tag:Name,Values=*${CLUSTER_NAME}*" \
  --profile "$AWS_PROFILE" --region "$AWS_REGION" \
  --query 'Vpcs[].{VpcId:VpcId,Name:Tags[?Key==`Name`].Value|[0]}' --output json 2>/dev/null || echo "[]")

VPC_CLEANUP_COUNT=$(echo "$ALL_REMAINING_VPCS" | jq 'length')

if [[ "$VPC_CLEANUP_COUNT" -gt 0 ]]; then
  log_warn "Found ${VPC_CLEANUP_COUNT} VPC(s) still remaining — cleaning up..."
  for VPC_ID in $(echo "$ALL_REMAINING_VPCS" | jq -r '.[].VpcId'); do
    cleanup_vpc "$VPC_ID"
  done
else
  log_ok "No remaining VPCs to clean up"
fi

# ── Clean up EFS file systems with no mount targets (orphaned) ────────────────
for FS_ID in $(aws efs describe-file-systems --profile "$AWS_PROFILE" --region "$AWS_REGION" \
  --query "FileSystems[?Tags[?Key=='Name' && contains(Value, '${CLUSTER_NAME}')]].FileSystemId" \
  --output text 2>/dev/null || echo ""); do
  # Delete access points first
  for AP_ID in $(aws efs describe-access-points --file-system-id "$FS_ID" \
    --profile "$AWS_PROFILE" --region "$AWS_REGION" \
    --query 'AccessPoints[].AccessPointId' --output text 2>/dev/null || echo ""); do
    log_info "Deleting EFS access point ${AP_ID}..."
    aws efs delete-access-point --access-point-id "$AP_ID" \
      --profile "$AWS_PROFILE" --region "$AWS_REGION" 2>/dev/null || true
  done
  # Delete remaining mount targets
  for MT_ID in $(aws efs describe-mount-targets --file-system-id "$FS_ID" \
    --profile "$AWS_PROFILE" --region "$AWS_REGION" \
    --query 'MountTargets[].MountTargetId' --output text 2>/dev/null || echo ""); do
    aws efs delete-mount-target --mount-target-id "$MT_ID" \
      --profile "$AWS_PROFILE" --region "$AWS_REGION" 2>/dev/null || true
  done
  # Wait for mount targets to finish deleting
  sleep 15
  log_info "Deleting EFS file system ${FS_ID}..."
  aws efs delete-file-system --file-system-id "$FS_ID" \
    --profile "$AWS_PROFILE" --region "$AWS_REGION" 2>/dev/null || true
done

# =============================================================================
section "PHASE 7 — TERRAFORM STATE CLEANUP"
# =============================================================================

# If resources were force-deleted from AWS, the Terraform state may reference
# resources that no longer exist. A targeted refresh + prune handles this.

log_info "Synchronising Terraform state with AWS..."

terraform init -reconfigure 2>&1 | tee -a "${LOG_FILE}" > /dev/null || true

# Refresh state — marks destroyed resources as gone
terraform refresh 2>&1 | tee -a "${LOG_FILE}" > /dev/null || true

# Remove any remaining resources from state that were force-deleted
REMAINING_RESOURCES=$(terraform state list 2>/dev/null || echo "")
if [[ -n "$REMAINING_RESOURCES" ]]; then
  log_warn "Terraform state still has resources — running final destroy..."
  terraform destroy -auto-approve 2>&1 | tee -a "${LOG_FILE}" || true

  # If destroy fails, force-remove remaining state entries
  STILL_REMAINING=$(terraform state list 2>/dev/null || echo "")
  if [[ -n "$STILL_REMAINING" ]]; then
    log_warn "Force-removing stale state entries..."
    while IFS= read -r RESOURCE; do
      [[ -z "$RESOURCE" ]] && continue
      log_info "  Removing from state: ${RESOURCE}"
      terraform state rm "$RESOURCE" 2>/dev/null || true
    done <<< "$STILL_REMAINING"
    log_ok "Terraform state cleaned"
  fi
else
  log_ok "Terraform state is clean — no resources remain"
fi

# =============================================================================
section "PHASE 8 — VERIFY CLEANUP"
# =============================================================================

log_info "Verifying resource cleanup..."
VERIFY_FAILED=false

# Check S3 bucket
BUCKET_NAME="ai-demo-data-lake"
if aws s3api head-bucket --bucket "$BUCKET_NAME" --profile "$AWS_PROFILE" 2>/dev/null; then
  log_warn "S3 bucket ${BUCKET_NAME} still exists — emptying and deleting..."
  aws s3 rm "s3://${BUCKET_NAME}" --recursive --profile "$AWS_PROFILE" 2>/dev/null || true
  aws s3api delete-bucket --bucket "$BUCKET_NAME" --profile "$AWS_PROFILE" 2>/dev/null || true
  if aws s3api head-bucket --bucket "$BUCKET_NAME" --profile "$AWS_PROFILE" 2>/dev/null; then
    log_fail "S3 bucket ${BUCKET_NAME} could not be deleted"
    VERIFY_FAILED=true
  else
    log_ok "S3 bucket cleaned up"
  fi
else
  log_ok "S3 bucket cleaned up"
fi

# Check VPCs
VPC_COUNT=$(aws ec2 describe-vpcs \
  --filters "Name=tag:Name,Values=*${CLUSTER_NAME}*" \
  --profile "$AWS_PROFILE" --region "$AWS_REGION" \
  --query 'Vpcs | length(@)' --output text 2>/dev/null || echo "0")
if [[ "$VPC_COUNT" -gt 0 ]]; then
  log_fail "VPC(s) still exist matching '${CLUSTER_NAME}'"
  aws ec2 describe-vpcs --filters "Name=tag:Name,Values=*${CLUSTER_NAME}*" \
    --profile "$AWS_PROFILE" --region "$AWS_REGION" \
    --query 'Vpcs[].{VpcId:VpcId,Name:Tags[?Key==`Name`].Value|[0]}' --output table 2>/dev/null || true
  VERIFY_FAILED=true
else
  log_ok "All VPCs cleaned up"
fi

# Check RDS
RDS_COUNT=$(aws rds describe-db-clusters --profile "$AWS_PROFILE" --region "$AWS_REGION" \
  --query "DBClusters[?contains(DBClusterIdentifier, '${CLUSTER_NAME}')] | length(@)" \
  --output text 2>/dev/null || echo "0")
if [[ "$RDS_COUNT" -gt 0 ]]; then
  log_warn "Aurora cluster(s) still exist (may be deleting)"
else
  log_ok "Aurora cleaned up"
fi

# Check EFS
EFS_COUNT=$(aws efs describe-file-systems --profile "$AWS_PROFILE" --region "$AWS_REGION" \
  --query "FileSystems[?Tags[?Key=='Name' && contains(Value, '${CLUSTER_NAME}')]] | length(@)" \
  --output text 2>/dev/null || echo "0")
if [[ "$EFS_COUNT" -gt 0 ]]; then
  log_warn "EFS file system(s) still exist (may be deleting)"
else
  log_ok "EFS cleaned up"
fi

# Check for orphaned EIPs
EIP_COUNT=$(aws ec2 describe-addresses --profile "$AWS_PROFILE" --region "$AWS_REGION" \
  --query 'Addresses[?AssociationId==null] | length(@)' --output text 2>/dev/null || echo "0")
if [[ "$EIP_COUNT" -gt 0 ]]; then
  log_warn "${EIP_COUNT} unassociated Elastic IP(s) remain — releasing..."
  for ALLOC_ID in $(aws ec2 describe-addresses --profile "$AWS_PROFILE" --region "$AWS_REGION" \
    --query 'Addresses[?AssociationId==null].AllocationId' --output text 2>/dev/null || echo ""); do
    aws ec2 release-address --allocation-id "$ALLOC_ID" \
      --profile "$AWS_PROFILE" --region "$AWS_REGION" 2>/dev/null || true
  done
  log_ok "Elastic IPs released"
else
  log_ok "No orphaned Elastic IPs"
fi

if [[ "$VERIFY_FAILED" == "true" ]]; then
  log_fail "Some resources could not be fully cleaned up — check warnings above"
else
  log_ok "All resources verified clean"
fi

# =============================================================================
section "PHASE 9 — RESIDUAL CLEANUP (so next ./deploy.sh starts clean)"
# =============================================================================
#
# These don't cost money but break re-provisioning if left around:
#   - SSM parameters (terraform fails with "ParameterAlreadyExists")
#   - Aurora subnet/parameter groups (orphan after manual cluster deletion)
#   - openshift-install state in ocp-install-dir (confuses fresh installer)
#   - errored.tfstate (terraform refuses to plan if present)
#   - generated machinesets (regenerated each apply, harmless but noisy)

log_info "Cleaning residual SSM parameters..."
aws ssm delete-parameters \
  --names /ai-demo/aurora/endpoint /ai-demo/aurora/database-name \
          /ai-demo/aurora/master-password /ai-demo/efs/file-system-id \
  --profile "$AWS_PROFILE" --region "$AWS_REGION" 2>&1 | head -3 || true

log_info "Cleaning residual Aurora subnet group + parameter group..."
aws rds delete-db-subnet-group --db-subnet-group-name "${CLUSTER_NAME}-db-subnet" \
  --profile "$AWS_PROFILE" --region "$AWS_REGION" 2>/dev/null || true
aws rds delete-db-cluster-parameter-group --db-cluster-parameter-group-name "${CLUSTER_NAME}-db-params" \
  --profile "$AWS_PROFILE" --region "$AWS_REGION" 2>/dev/null || true

log_info "Cleaning local state files..."
rm -rf "${ENV_DIR}/ocp-install-dir/${CLUSTER_NAME}" 2>/dev/null || true
rm -f "${ENV_DIR}/errored.tfstate" "${ENV_DIR}/tfplan" 2>/dev/null || true
rm -rf "${ENV_DIR}/generated" 2>/dev/null || true

log_ok "Residual cleanup complete — repo ready for fresh ./deploy.sh"

# =============================================================================
section "TEARDOWN COMPLETE"
# =============================================================================

echo ""
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${GREEN}${BOLD}║                  TEARDOWN COMPLETE                                  ║${RESET}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════════════════════╝${RESET}"
echo ""

print_summary
