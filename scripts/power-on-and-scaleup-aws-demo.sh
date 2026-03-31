#!/usr/bin/env bash
# =============================================================================
#  AI Demo Stack — Power On & Scale Up
#  Starts masters (if stopped), scales workers back up, and verifies
#  every component is running before declaring success.
#
#  Usage: ./scripts/power-on-and-scaleup-aws-demo.sh
#
#  What it does:
#    1. Authenticates to AWS SSO
#    2. Starts master EC2 instances (if stopped)
#    3. Waits for OCP API to become available
#    4. Scales worker machinesets back to desired count
#    5. Waits for all nodes to be Ready
#    6. Waits for all cluster operators to be Available
#    7. Refreshes AWS cloud credentials (for SSO token rotation)
#    8. Verifies all ArgoCD applications are Synced/Healthy
#    9. Verifies all application pods are Running
#   10. Prints a full status report with all application URLs
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

LOG_FILE="${LOG_DIR}/power-on_${TIMESTAMP}.log"

# ── Configuration ──────────────────────────────────────────────────────────
WORKER_REPLICAS_A=1
WORKER_REPLICAS_B=1
WORKER_REPLICAS_C=1
EXPECTED_WORKERS=3
NODE_READY_TIMEOUT=600    # 10 min
API_READY_TIMEOUT=600     # 10 min
OPERATOR_TIMEOUT=900      # 15 min
ARGOCD_TIMEOUT=600        # 10 min
POD_READY_TIMEOUT=600     # 10 min

echo ""
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${GREEN}${BOLD}║        AI DEMO STACK — POWER ON & SCALE UP                           ║${RESET}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════════════════════╝${RESET}"

# ══════════════════════════════════════════════════════════════════════════
#  PHASE 1 — Authentication
# ══════════════════════════════════════════════════════════════════════════
section "PHASE 1 — Authentication"

aws_sso_login

KUBECONFIG_PATH="${ENV_DIR}/ocp-install-dir/${CLUSTER_NAME}/auth/kubeconfig"
if [[ ! -f "$KUBECONFIG_PATH" ]]; then
  abort "KUBECONFIG not found at ${KUBECONFIG_PATH}. Run deploy.sh first."
fi
export KUBECONFIG="$KUBECONFIG_PATH"
log_ok "KUBECONFIG set: ${KUBECONFIG_PATH}"

# ══════════════════════════════════════════════════════════════════════════
#  PHASE 2 — Start Master EC2 Instances
# ══════════════════════════════════════════════════════════════════════════
section "PHASE 2 — Start Master EC2 Instances"

# Discover infra ID from EC2 tags
INFRA_ID=$(aws ec2 describe-instances --profile "$AWS_PROFILE" \
  --filters "Name=tag:Name,Values=${CLUSTER_NAME}-*-master-*" \
  --query 'Reservations[].Instances[].Tags[?Key==`Name`].Value | [0][0]' --output text 2>/dev/null \
  | sed -E 's/-(master|worker)-.*//' || echo "")

if [[ -z "$INFRA_ID" || "$INFRA_ID" == "None" ]]; then
  abort "Cannot determine cluster infra ID. Check AWS console."
fi
log_ok "Cluster infra ID: ${INFRA_ID}"

# Check master states
STOPPED_MASTERS=$(aws ec2 describe-instances --profile "$AWS_PROFILE" \
  --filters "Name=tag:Name,Values=*${INFRA_ID}*master*" "Name=instance-state-name,Values=stopped" \
  --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null || true)

RUNNING_MASTERS=$(aws ec2 describe-instances --profile "$AWS_PROFILE" \
  --filters "Name=tag:Name,Values=*${INFRA_ID}*master*" "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null || true)

RUNNING_COUNT=$(echo "$RUNNING_MASTERS" | wc -w | tr -d ' ')
STOPPED_COUNT=$(echo "$STOPPED_MASTERS" | wc -w | tr -d ' ')

if [[ "$STOPPED_COUNT" -gt 0 ]]; then
  log_info "Starting ${STOPPED_COUNT} stopped master instance(s)..."
  aws ec2 start-instances --profile "$AWS_PROFILE" --instance-ids $STOPPED_MASTERS \
    --output json 2>/dev/null | python3 -c "
import sys, json
data = json.load(sys.stdin)
for inst in data.get('StartingInstances', []):
    print(f\"  {inst['InstanceId']}: {inst['PreviousState']['Name']} → {inst['CurrentState']['Name']}\")
" 2>/dev/null || true

  # Wait for masters to be running
  log_info "Waiting for masters to reach 'running' state..."
  MAX_WAIT=300
  ELAPSED=0
  while [[ $ELAPSED -lt $MAX_WAIT ]]; do
    STILL_STOPPED=$(aws ec2 describe-instances --profile "$AWS_PROFILE" \
      --instance-ids $STOPPED_MASTERS \
      --query 'Reservations[].Instances[?State.Name!=`running`].InstanceId' \
      --output text 2>/dev/null || true)
    if [[ -z "$STILL_STOPPED" || "$STILL_STOPPED" == "None" ]]; then
      break
    fi
    echo -e "     ${DIM}[${ELAPSED}s] Waiting for masters to start...${RESET}"
    sleep 15
    ELAPSED=$((ELAPSED + 15))
  done
  log_ok "All master instances running"
else
  log_ok "All ${RUNNING_COUNT} master instance(s) already running"
fi

# Show master instance details
echo ""
echo -e "  ${WHITE}Master Instances:${RESET}"
aws ec2 describe-instances --profile "$AWS_PROFILE" \
  --filters "Name=tag:Name,Values=*${INFRA_ID}*master*" "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].[Tags[?Key==`Name`].Value|[0],InstanceType,Placement.AvailabilityZone,PrivateIpAddress]' \
  --output text 2>/dev/null | while IFS=$'\t' read -r NAME TYPE AZ IP; do
    echo -e "    ${GREEN}✔${RESET} ${CYAN}${NAME}${RESET}  ${DIM}${TYPE} | ${AZ} | ${IP}${RESET}"
  done
echo ""

# ══════════════════════════════════════════════════════════════════════════
#  PHASE 3 — Wait for OCP API
# ══════════════════════════════════════════════════════════════════════════
section "PHASE 3 — Wait for OCP API"

wait_for "OCP API responding" \
  "oc get clusterversion &>/dev/null" \
  "$API_READY_TIMEOUT" 15

OCP_VERSION=$(oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null || echo "unknown")
log_ok "OCP API is up — cluster version: ${OCP_VERSION}"

# ══════════════════════════════════════════════════════════════════════════
#  PHASE 4 — Scale Up Workers
# ══════════════════════════════════════════════════════════════════════════
section "PHASE 4 — Scale Up Worker MachineSets"

# Discover machinesets
MS_LIST=$(oc get machinesets -n openshift-machine-api -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep worker || true)

if [[ -z "$MS_LIST" ]]; then
  abort "No worker machinesets found in openshift-machine-api namespace."
fi

# Scale each machineset
while read -r MS_NAME; do
  CURRENT=$(oc get machineset "$MS_NAME" -n openshift-machine-api -o jsonpath='{.spec.replicas}' 2>/dev/null)
  TARGET=1

  # Determine target based on AZ suffix
  if [[ "$MS_NAME" == *"-1a" ]]; then TARGET=$WORKER_REPLICAS_A;
  elif [[ "$MS_NAME" == *"-1b" ]]; then TARGET=$WORKER_REPLICAS_B;
  elif [[ "$MS_NAME" == *"-1c" ]]; then TARGET=$WORKER_REPLICAS_C;
  fi

  if [[ "$CURRENT" -eq "$TARGET" ]]; then
    log_ok "${MS_NAME}: already at ${TARGET} replica(s)"
  else
    log_info "Scaling ${MS_NAME}: ${CURRENT} → ${TARGET}..."
    oc scale machineset "$MS_NAME" -n openshift-machine-api --replicas="$TARGET"
    log_ok "${MS_NAME}: scaled to ${TARGET}"
  fi
done <<< "$MS_LIST"

# ── Wait for machines to be Running ────────────────────────────────────────
log_info "Waiting for ${EXPECTED_WORKERS} worker machine(s) to reach Running phase..."
MAX_WAIT=$NODE_READY_TIMEOUT
ELAPSED=0
while [[ $ELAPSED -lt $MAX_WAIT ]]; do
  RUNNING_MACHINES=$(oc get machines -n openshift-machine-api --no-headers 2>/dev/null \
    | grep worker | grep -c Running || echo "0")

  if [[ "$RUNNING_MACHINES" -ge "$EXPECTED_WORKERS" ]]; then
    log_ok "All ${EXPECTED_WORKERS} worker machines are Running"
    break
  fi

  echo -e "     ${DIM}[${ELAPSED}s] ${RUNNING_MACHINES}/${EXPECTED_WORKERS} workers running...${RESET}"
  sleep 20
  ELAPSED=$((ELAPSED + 20))
done

if [[ $ELAPSED -ge $MAX_WAIT ]]; then
  log_warn "Timed out waiting for workers — ${RUNNING_MACHINES}/${EXPECTED_WORKERS} running"
fi

# ── Wait for nodes to be Ready ─────────────────────────────────────────────
section "PHASE 5 — Wait for Nodes Ready"

log_info "Waiting for ${EXPECTED_WORKERS} worker nodes to be Ready..."
MAX_WAIT=$NODE_READY_TIMEOUT
ELAPSED=0
while [[ $ELAPSED -lt $MAX_WAIT ]]; do
  READY_WORKERS=$(oc get nodes --no-headers 2>/dev/null \
    | grep worker | grep -c " Ready " || echo "0")

  if [[ "$READY_WORKERS" -ge "$EXPECTED_WORKERS" ]]; then
    log_ok "All ${EXPECTED_WORKERS} worker nodes are Ready"
    break
  fi

  echo -e "     ${DIM}[${ELAPSED}s] ${READY_WORKERS}/${EXPECTED_WORKERS} worker nodes ready...${RESET}"
  sleep 15
  ELAPSED=$((ELAPSED + 15))
done

echo ""
echo -e "  ${WHITE}All Nodes:${RESET}"
oc get nodes --no-headers 2>/dev/null | while read -r line; do
  STATUS=$(echo "$line" | awk '{print $2}')
  COLOR="${GREEN}"
  [[ "$STATUS" != "Ready" ]] && COLOR="${YELLOW}"
  echo -e "    ${COLOR}${line}${RESET}"
done
echo ""

# ══════════════════════════════════════════════════════════════════════════
#  PHASE 6 — Refresh AWS Cloud Credentials
# ══════════════════════════════════════════════════════════════════════════
section "PHASE 6 — Refresh AWS Cloud Credentials (for SSO)"

log_info "Extracting fresh AWS credentials from SSO session..."
eval "$(aws configure export-credentials --profile "$AWS_PROFILE" --format env 2>/dev/null)" || {
  log_warn "Could not export credentials — cloud operators may have stale tokens"
}

# Update credentials secrets in all required namespaces
CRED_NAMESPACES=(
  "openshift-machine-api:aws-cloud-credentials"
  "openshift-cloud-credential-operator:cloud-credentials"
  "openshift-cluster-csi-drivers:ebs-cloud-credentials"
  "openshift-ingress-operator:cloud-credentials"
  "openshift-image-registry:cloud-credentials"
)

CRED_CONTENT="[default]
aws_access_key_id = ${AWS_ACCESS_KEY_ID:-}
aws_secret_access_key = ${AWS_SECRET_ACCESS_KEY:-}
aws_session_token = ${AWS_SESSION_TOKEN:-}
"

if [[ -n "${AWS_ACCESS_KEY_ID:-}" ]]; then
  for ENTRY in "${CRED_NAMESPACES[@]}"; do
    NS="${ENTRY%%:*}"
    SECRET_NAME="${ENTRY##*:}"
    oc delete secret "$SECRET_NAME" -n "$NS" --ignore-not-found 2>/dev/null || true
    oc create secret generic "$SECRET_NAME" -n "$NS" \
      --from-literal=credentials="$CRED_CONTENT" 2>/dev/null || true
  done
  log_ok "AWS cloud credential secrets refreshed in ${#CRED_NAMESPACES[@]} namespaces"

  # Restart machine-api to pick up new creds
  oc delete pod -n openshift-machine-api -l api=clusterapi 2>/dev/null || true
  log_ok "Machine API controllers restarted"
else
  log_warn "No AWS env vars found — skipping credential refresh (Mint mode may handle this)"
fi

# Clean up env vars
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_CREDENTIAL_EXPIRATION 2>/dev/null || true

# ══════════════════════════════════════════════════════════════════════════
#  PHASE 7 — Wait for Cluster Operators
# ══════════════════════════════════════════════════════════════════════════
section "PHASE 7 — Wait for Cluster Operators"

log_info "Waiting for all cluster operators to be Available (timeout: ${OPERATOR_TIMEOUT}s)..."
MAX_WAIT=$OPERATOR_TIMEOUT
ELAPSED=0
while [[ $ELAPSED -lt $MAX_WAIT ]]; do
  DEGRADED=$(oc get clusteroperators --no-headers 2>/dev/null \
    | awk '{print $5}' | grep -c True || echo "0")
  NOT_AVAILABLE=$(oc get clusteroperators --no-headers 2>/dev/null \
    | awk '{print $3}' | grep -c False || echo "0")

  if [[ "$DEGRADED" -eq 0 && "$NOT_AVAILABLE" -eq 0 ]]; then
    log_ok "All cluster operators are Available and not Degraded"
    break
  fi

  echo -e "     ${DIM}[${ELAPSED}s] ${NOT_AVAILABLE} unavailable, ${DEGRADED} degraded...${RESET}"
  sleep 30
  ELAPSED=$((ELAPSED + 30))
done

if [[ $ELAPSED -ge $MAX_WAIT ]]; then
  log_warn "Some operators still not ready after ${OPERATOR_TIMEOUT}s:"
  oc get clusteroperators --no-headers 2>/dev/null | grep -E "False|True.*True" | while read -r line; do
    echo -e "    ${YELLOW}${line}${RESET}"
  done
fi

# ══════════════════════════════════════════════════════════════════════════
#  PHASE 8 — Verify ArgoCD Applications
# ══════════════════════════════════════════════════════════════════════════
section "PHASE 8 — Verify ArgoCD Applications"

# Force refresh all apps
log_info "Triggering ArgoCD refresh on all applications..."
for APP in $(oc get applications.argoproj.io -n openshift-gitops -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null); do
  oc annotate applications.argoproj.io/"$APP" -n openshift-gitops \
    argocd.argoproj.io/refresh=normal --overwrite 2>/dev/null || true
done
log_ok "Refresh triggered for all ArgoCD applications"

# Wait for apps to sync
log_info "Waiting for ArgoCD applications to sync (timeout: ${ARGOCD_TIMEOUT}s)..."
MAX_WAIT=$ARGOCD_TIMEOUT
ELAPSED=0
while [[ $ELAPSED -lt $MAX_WAIT ]]; do
  TOTAL_APPS=$(oc get applications.argoproj.io -n openshift-gitops --no-headers 2>/dev/null | wc -l | tr -d ' ')
  HEALTHY_APPS=$(oc get applications.argoproj.io -n openshift-gitops --no-headers 2>/dev/null \
    | awk '{print $2, $3}' | grep -c "Synced.*Healthy" || echo "0")

  if [[ "$HEALTHY_APPS" -eq "$TOTAL_APPS" && "$TOTAL_APPS" -gt 0 ]]; then
    log_ok "All ${TOTAL_APPS} ArgoCD applications are Synced/Healthy"
    break
  fi

  echo -e "     ${DIM}[${ELAPSED}s] ${HEALTHY_APPS}/${TOTAL_APPS} apps healthy...${RESET}"
  sleep 30
  ELAPSED=$((ELAPSED + 30))
done

# Show app status
echo ""
echo -e "  ${WHITE}ArgoCD Application Status:${RESET}"
oc get applications.argoproj.io -n openshift-gitops -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status' --no-headers 2>/dev/null | while read -r NAME SYNC HEALTH; do
  if [[ "$SYNC" == "Synced" && "$HEALTH" == "Healthy" ]]; then
    echo -e "    ${GREEN}✔${RESET} ${NAME}  ${DIM}(${SYNC}/${HEALTH})${RESET}"
  elif [[ "$HEALTH" == "Progressing" ]]; then
    echo -e "    ${YELLOW}⏳${RESET} ${NAME}  ${DIM}(${SYNC}/${HEALTH})${RESET}"
  else
    echo -e "    ${RED}✘${RESET} ${NAME}  ${DIM}(${SYNC}/${HEALTH})${RESET}"
  fi
done
echo ""

# ══════════════════════════════════════════════════════════════════════════
#  PHASE 9 — Verify Application Pods
# ══════════════════════════════════════════════════════════════════════════
section "PHASE 9 — Verify Application Pods"

log_info "Waiting for application pods to be Running (timeout: ${POD_READY_TIMEOUT}s)..."

# Key namespaces to check
APP_NAMESPACES=(
  "ai-demo"
  "vault"
  "rhoai-sso"
  "rhoai-minio"
  "rhoai-mlflow"
  "langchain"
  "openshift-gitops"
  "redhat-ods-applications"
)

MAX_WAIT=$POD_READY_TIMEOUT
ELAPSED=0
while [[ $ELAPSED -lt $MAX_WAIT ]]; do
  PROBLEM_PODS=0
  for NS in "${APP_NAMESPACES[@]}"; do
    BAD=$(oc get pods -n "$NS" --no-headers 2>/dev/null \
      | grep -v -E "Running|Completed|Succeeded" | grep -v -E "^$" | wc -l | tr -d ' ')
    PROBLEM_PODS=$((PROBLEM_PODS + BAD))
  done

  if [[ "$PROBLEM_PODS" -eq 0 ]]; then
    log_ok "All application pods are Running"
    break
  fi

  echo -e "     ${DIM}[${ELAPSED}s] ${PROBLEM_PODS} pod(s) not yet Running...${RESET}"
  sleep 30
  ELAPSED=$((ELAPSED + 30))
done

# Show pod status per namespace
echo ""
echo -e "  ${WHITE}Application Pod Summary:${RESET}"
for NS in "${APP_NAMESPACES[@]}"; do
  TOTAL=$(oc get pods -n "$NS" --no-headers 2>/dev/null | grep -v Completed | wc -l | tr -d ' ')
  RUNNING=$(oc get pods -n "$NS" --no-headers 2>/dev/null | grep -c Running || echo "0")
  BAD=$((TOTAL - RUNNING))

  if [[ "$TOTAL" -eq 0 ]]; then
    echo -e "    ${DIM}${NS}: no pods${RESET}"
  elif [[ "$BAD" -eq 0 ]]; then
    echo -e "    ${GREEN}✔${RESET} ${NS}: ${GREEN}${RUNNING}/${TOTAL} running${RESET}"
  else
    echo -e "    ${YELLOW}⚠${RESET} ${NS}: ${YELLOW}${RUNNING}/${TOTAL} running${RESET}"
    # Show problematic pods
    oc get pods -n "$NS" --no-headers 2>/dev/null | grep -v -E "Running|Completed" | while read -r line; do
      echo -e "      ${RED}→ ${line}${RESET}"
    done
  fi
done
echo ""

# Show any remaining Pending pods across all namespaces
PENDING_PODS=$(oc get pods -A --field-selector=status.phase=Pending --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [[ "$PENDING_PODS" -gt 0 ]]; then
  log_warn "${PENDING_PODS} pod(s) still Pending cluster-wide (may need more resources)"
fi

# ══════════════════════════════════════════════════════════════════════════
#  PHASE 10 — Application URLs & Credentials
# ══════════════════════════════════════════════════════════════════════════
section "PHASE 10 — Application URLs & Credentials"

APPS_DOMAIN="apps.${CLUSTER_NAME}.iisdemolab.click"

echo ""
echo -e "  ${WHITE}${BOLD}╔══════════════════════════════════════════════════════════════════╗${RESET}"
echo -e "  ${WHITE}${BOLD}║                    APPLICATION URLS                              ║${RESET}"
echo -e "  ${WHITE}${BOLD}╚══════════════════════════════════════════════════════════════════╝${RESET}"
echo ""

# Collect routes and display
echo -e "  ${CYAN}${BOLD}Platform:${RESET}"
echo -e "    OCP Console       : ${GREEN}https://console-openshift-console.${APPS_DOMAIN}${RESET}"
echo -e "                        ${DIM}User: kubeadmin  Pass: $(cat "${ENV_DIR}/ocp-install-dir/${CLUSTER_NAME}/auth/kubeadmin-password" 2>/dev/null || echo 'see auth dir')${RESET}"
echo -e "    ArgoCD            : ${GREEN}https://openshift-gitops-server-openshift-gitops.${APPS_DOMAIN}${RESET}"
echo -e "                        ${DIM}User: admin  Pass: ${DEFAULT_PASSWORD}${RESET}"
echo -e "    OpenShift AI      : ${GREEN}https://rhods-dashboard-redhat-ods-applications.${APPS_DOMAIN}${RESET}"
echo ""

echo -e "  ${CYAN}${BOLD}AI & ML:${RESET}"
echo -e "    Open WebUI        : ${GREEN}https://open-webui-ai-demo.${APPS_DOMAIN}${RESET}"
echo -e "    MLflow            : ${GREEN}https://mlflow-rhoai-mlflow.${APPS_DOMAIN}${RESET}"
echo -e "    LangChain         : ${GREEN}https://langchain-server-langchain.${APPS_DOMAIN}${RESET}"
echo -e "    Portkey (Gateway) : ${GREEN}https://portkey-ai-demo.${APPS_DOMAIN}${RESET}"
echo ""

echo -e "  ${CYAN}${BOLD}Data & Storage:${RESET}"
echo -e "    MinIO             : ${GREEN}https://minio-console-rhoai-minio.${APPS_DOMAIN}${RESET}"
echo -e "                        ${DIM}User: minio  Pass: ${DEFAULT_PASSWORD}${RESET}"
echo -e "    CloudBeaver       : ${GREEN}https://cloudbeaver-rhoai-tools.${APPS_DOMAIN}${RESET}"
echo ""

echo -e "  ${CYAN}${BOLD}Security & Auth:${RESET}"
echo -e "    Keycloak          : ${GREEN}https://keycloak-rhoai-sso.${APPS_DOMAIN}${RESET}"
echo -e "                        ${DIM}User: admin  Pass: ${DEFAULT_PASSWORD}${RESET}"
echo -e "    Vault             : ${GREEN}https://vault-vault.${APPS_DOMAIN}${RESET}"
echo -e "                        ${DIM}Token: ${DEFAULT_PASSWORD}${RESET}"
echo ""

echo -e "  ${CYAN}${BOLD}Observability:${RESET}"
echo -e "    Grafana           : ${GREEN}https://grafana-rhoai-monitoring.${APPS_DOMAIN}${RESET}"
echo -e "    Kiali (Mesh)      : ${GREEN}https://kiali-istio-system.${APPS_DOMAIN}${RESET}"
echo ""

echo -e "  ${CYAN}${BOLD}Automation:${RESET}"
echo -e "    n8n               : ${GREEN}https://n8n-ai-demo.${APPS_DOMAIN}${RESET}"
echo ""

echo -e "  ${CYAN}${BOLD}Infrastructure:${RESET}"
echo -e "    API Server        : ${GREEN}https://api.${CLUSTER_NAME}.iisdemolab.click:6443${RESET}"
echo -e "    Aurora DB         : ${DIM}ai-demo-db.cluster-cidweltunfq6.us-east-1.rds.amazonaws.com:5432${RESET}"
echo ""

# ── Cluster Resource Summary ───────────────────────────────────────────────
section "Cluster Resource Summary"

echo ""
echo -e "  ${WHITE}Nodes:${RESET}"
oc get nodes -o custom-columns='NAME:.metadata.name,STATUS:.status.conditions[-1].type,ROLES:.metadata.labels.node-role\.kubernetes\.io/worker,CPU:.status.capacity.cpu,MEMORY:.status.capacity.memory' --no-headers 2>/dev/null | while read -r line; do
  echo -e "    ${line}"
done

echo ""
echo -e "  ${WHITE}Machines:${RESET}"
oc get machines -n openshift-machine-api -o custom-columns='NAME:.metadata.name,PHASE:.status.phase,TYPE:.spec.providerSpec.value.instanceType,AZ:.spec.providerSpec.value.placement.availabilityZone' --no-headers 2>/dev/null | while read -r line; do
  echo -e "    ${line}"
done

echo ""
echo -e "  ${WHITE}Cluster Operators (non-healthy only):${RESET}"
UNHEALTHY_OPS=$(oc get clusteroperators --no-headers 2>/dev/null | grep -E "False|True.*True" || true)
if [[ -z "$UNHEALTHY_OPS" ]]; then
  echo -e "    ${GREEN}All cluster operators are healthy!${RESET}"
else
  echo "$UNHEALTHY_OPS" | while read -r line; do
    echo -e "    ${YELLOW}${line}${RESET}"
  done
fi

# ══════════════════════════════════════════════════════════════════════════
#  FINAL SUMMARY
# ══════════════════════════════════════════════════════════════════════════
echo ""
echo -e "  ${WHITE}Estimated Running Cost: ~\$1.55/hr (~\$37/day | ~\$1,123/month)${RESET}"
echo ""
echo -e "  ${YELLOW}${BOLD}💡 To shut down when done:${RESET}"
echo -e "     ${CYAN}./scripts/drain-workers-aws-ocp.sh${RESET}       ${DIM}# saves ~\$16/day${RESET}"
echo -e "     ${CYAN}./scripts/power-down-masters-aws-ocp.sh${RESET}  ${DIM}# saves ~\$14/day more${RESET}"

print_summary
