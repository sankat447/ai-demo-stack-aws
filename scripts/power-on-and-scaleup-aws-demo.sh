#!/usr/bin/env bash
# =============================================================================
#  AI Demo Stack — Power On & Scale Up
#  Starts masters (if stopped), scales workers back up, and verifies
#  every component is running before declaring success.
#
#  Usage: ./scripts/power-on-and-scaleup-aws-demo.sh
#
#  Lessons learned & built-in fixes:
#    - CCO (cloud-credential-operator) uses Mint mode with static IAM creds
#      in kube-system/aws-creds. NEVER inject SSO session tokens into
#      cloud credential secrets — they expire and break EBS CSI, image
#      registry, machine API, and ingress.
#    - After masters restart, CCO may fail to update secrets if stale STS
#      session tokens are present. Fix: delete stale secrets, restart CCO.
#    - GPU/NFD operator subscriptions must install before their CRs
#      (ClusterPolicy, NodeFeatureDiscovery) because CRDs don't exist yet.
#    - KServe CRDs (InferenceService, ServingRuntime) require RHOAI to
#      finish installing — llama-inference and vllm-runtime apps will only
#      sync after RHOAI is ready.
#    - EBS CSI controller pods must be restarted after credential refresh
#      to pick up new IAM access keys from CCO.
#
#  What it does:
#    1. Authenticates to AWS SSO
#    2. Starts master EC2 instances (if stopped)
#    3. Waits for OCP API to become available
#    4. Scales worker machinesets back to desired count
#    5. Waits for all nodes to be Ready
#    6. Refreshes cloud credentials (CCO Mint mode — deletes stale secrets)
#    7. Waits for all cluster operators to be Available
#    8. Verifies ArgoCD applications and force-syncs stuck apps
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
CCO_TIMEOUT=300           # 5 min for cloud-credential-operator

echo ""
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${GREEN}${BOLD}║        AI DEMO STACK — POWER ON & SCALE UP                         ║${RESET}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════════════════════╝${RESET}"

# ══════════════════════════════════════════════════════════════════════════
#  PHASE 1 — Authentication
# ══════════════════════════════════════════════════════════════════════════
section "PHASE 1 — Authentication"

# Source reauth.sh for AWS SSO + KUBECONFIG + OCP connectivity
source "${SCRIPT_DIR}/reauth.sh"

if [[ -z "${KUBECONFIG:-}" ]]; then
  abort "KUBECONFIG not set. Run deploy.sh first."
fi
log_ok "KUBECONFIG set: ${KUBECONFIG}"

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
#  PHASE 6 — Refresh AWS Cloud Credentials (CCO Mint Mode)
# ══════════════════════════════════════════════════════════════════════════
section "PHASE 6 — Refresh AWS Cloud Credentials (CCO Mint Mode)"

# ┌─────────────────────────────────────────────────────────────────────────
# │ LESSON LEARNED: With credentialsMode: Mint, the cloud-credential-
# │ operator (CCO) creates and manages per-component IAM users using
# │ the static IAM credentials in kube-system/aws-creds.
# │
# │ NEVER inject SSO session tokens into cloud credential secrets!
# │ Session tokens expire (typically within 1-12 hours) and will break:
# │   - EBS CSI driver (can't create/attach volumes)
# │   - Machine API (can't create/delete EC2 instances)
# │   - Image Registry (can't push to S3)
# │   - Ingress (can't manage Route53 records)
# │
# │ After a power cycle, stale STS session tokens in existing secrets
# │ prevent CCO from updating them. Fix: delete stale secrets and let
# │ CCO re-mint fresh static IAM credentials.
# └─────────────────────────────────────────────────────────────────────────

# Step 6a: Verify root credentials exist and are static (not STS)
log_info "Verifying CCO root credentials in kube-system/aws-creds..."
ROOT_KEY_ID=$(oc get secret aws-creds -n kube-system -o jsonpath='{.data.aws_access_key_id}' 2>/dev/null | base64 -d 2>/dev/null || echo "")

if [[ -z "$ROOT_KEY_ID" ]]; then
  log_fail "Root AWS credentials (kube-system/aws-creds) not found!"
  log_warn "CCO cannot mint credentials without root creds. Cluster may be degraded."
elif [[ "$ROOT_KEY_ID" == AKIA* ]]; then
  log_ok "Root credentials are static IAM keys (${ROOT_KEY_ID:0:10}...)"
elif [[ "$ROOT_KEY_ID" == ASIA* ]]; then
  log_warn "Root credentials are STS session tokens — CCO may fail to mint!"
  log_warn "Consider replacing with static IAM user credentials."
else
  log_warn "Root credentials format unknown: ${ROOT_KEY_ID:0:10}..."
fi

# Step 6b: Check for stale STS session tokens in cloud credential secrets
log_info "Checking for stale STS session tokens in cloud credential secrets..."
STALE_SECRETS_FOUND=false

# These are the secrets CCO manages via Mint mode
CCO_MANAGED_SECRETS=(
  "openshift-cluster-csi-drivers:ebs-cloud-credentials"
  "openshift-cluster-csi-drivers:aws-efs-cloud-credentials"
  "openshift-ingress-operator:cloud-credentials"
  "openshift-machine-api:aws-cloud-credentials"
  "openshift-image-registry:installer-cloud-credentials"
  "openshift-cloud-network-config-controller:cloud-credentials"
)

for ENTRY in "${CCO_MANAGED_SECRETS[@]}"; do
  NS="${ENTRY%%:*}"
  SECRET_NAME="${ENTRY##*:}"

  # Check if secret exists and contains STS session tokens
  SECRET_CONTENT=$(oc get secret "$SECRET_NAME" -n "$NS" -o jsonpath='{.data.credentials}' 2>/dev/null | base64 -d 2>/dev/null || echo "")

  if [[ -z "$SECRET_CONTENT" ]]; then
    echo -e "     ${DIM}${NS}/${SECRET_NAME}: not found (CCO will create)${RESET}"
    continue
  fi

  if echo "$SECRET_CONTENT" | grep -q "aws_session_token"; then
    log_warn "${NS}/${SECRET_NAME}: contains stale STS session token — deleting"
    oc delete secret "$SECRET_NAME" -n "$NS" --ignore-not-found 2>/dev/null || true
    STALE_SECRETS_FOUND=true
  else
    # Check if the key is AKIA (static) — healthy state
    SECRET_KEY=$(echo "$SECRET_CONTENT" | grep aws_access_key_id | awk '{print $NF}')
    if [[ "$SECRET_KEY" == AKIA* ]]; then
      echo -e "     ${DIM}${NS}/${SECRET_NAME}: healthy static key (${SECRET_KEY:0:10}...)${RESET}"
    elif [[ "$SECRET_KEY" == ASIA* ]]; then
      log_warn "${NS}/${SECRET_NAME}: contains STS key without token field — deleting"
      oc delete secret "$SECRET_NAME" -n "$NS" --ignore-not-found 2>/dev/null || true
      STALE_SECRETS_FOUND=true
    fi
  fi
done

# Step 6c: Restart CCO if stale secrets were found
if [[ "$STALE_SECRETS_FOUND" == "true" ]]; then
  log_info "Stale secrets removed — restarting cloud-credential-operator to re-mint..."
  oc delete pod -l app=cloud-credential-operator -n openshift-cloud-credential-operator 2>/dev/null || true

  # Wait for CCO to reconcile and become healthy
  log_info "Waiting for CCO to re-mint credentials (timeout: ${CCO_TIMEOUT}s)..."
  MAX_WAIT=$CCO_TIMEOUT
  ELAPSED=0
  while [[ $ELAPSED -lt $MAX_WAIT ]]; do
    CCO_DEGRADED=$(oc get co cloud-credential -o jsonpath='{.status.conditions[?(@.type=="Degraded")].status}' 2>/dev/null || echo "Unknown")

    if [[ "$CCO_DEGRADED" == "False" ]]; then
      log_ok "Cloud-credential-operator is healthy (not degraded)"
      break
    fi

    echo -e "     ${DIM}[${ELAPSED}s] CCO still reconciling (Degraded=${CCO_DEGRADED})...${RESET}"
    sleep 15
    ELAPSED=$((ELAPSED + 15))
  done

  if [[ $ELAPSED -ge $MAX_WAIT ]]; then
    log_warn "CCO still degraded after ${CCO_TIMEOUT}s — credentials may not be fully refreshed"
    # Show which credential requests are failing
    oc get co cloud-credential -o jsonpath='{.status.conditions[?(@.type=="Degraded")].message}' 2>/dev/null || true
  fi

  # Step 6d: Restart EBS CSI controller to pick up new credentials
  log_info "Restarting EBS CSI controllers to pick up new credentials..."
  oc delete pods -l app=aws-ebs-csi-driver-controller -n openshift-cluster-csi-drivers 2>/dev/null || true
  log_ok "EBS CSI controllers restarted"

  # Also restart EFS CSI if present
  oc delete pods -l app=aws-efs-csi-driver-controller -n openshift-cluster-csi-drivers 2>/dev/null || true

else
  log_ok "All cloud credential secrets are healthy — no refresh needed"

  # Still verify CCO is not degraded
  CCO_DEGRADED=$(oc get co cloud-credential -o jsonpath='{.status.conditions[?(@.type=="Degraded")].status}' 2>/dev/null || echo "Unknown")
  if [[ "$CCO_DEGRADED" == "True" ]]; then
    log_warn "CCO is degraded even though secrets look OK — investigating..."
    CCO_MSG=$(oc get co cloud-credential -o jsonpath='{.status.conditions[?(@.type=="Degraded")].message}' 2>/dev/null || echo "unknown reason")
    log_warn "CCO degraded reason: ${CCO_MSG}"

    # Try restarting CCO to resolve
    log_info "Restarting CCO to attempt self-healing..."
    oc delete pod -l app=cloud-credential-operator -n openshift-cloud-credential-operator 2>/dev/null || true
    sleep 30

    CCO_DEGRADED=$(oc get co cloud-credential -o jsonpath='{.status.conditions[?(@.type=="Degraded")].status}' 2>/dev/null || echo "Unknown")
    if [[ "$CCO_DEGRADED" == "False" ]]; then
      log_ok "CCO recovered after restart"
    else
      log_warn "CCO still degraded — may need manual investigation"
    fi
  else
    log_ok "Cloud-credential-operator is healthy"
  fi
fi

# Clean up any lingering AWS env vars (SSO tokens must NOT leak into subprocesses)
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
#  PHASE 8 — Verify & Fix ArgoCD Applications
# ══════════════════════════════════════════════════════════════════════════
section "PHASE 8 — Verify & Fix ArgoCD Applications"

# Step 8a: Force refresh all apps to pick up any git changes
log_info "Triggering ArgoCD refresh on all applications..."
for APP in $(oc get applications.argoproj.io -n openshift-gitops -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null); do
  oc annotate applications.argoproj.io/"$APP" -n openshift-gitops \
    argocd.argoproj.io/refresh=normal --overwrite 2>/dev/null || true
done
log_ok "Refresh triggered for all ArgoCD applications"

# Step 8b: Wait for initial sync wave
log_info "Waiting 60s for initial ArgoCD sync wave..."
sleep 60

# Step 8c: Check for and fix known issues
# ┌─────────────────────────────────────────────────────────────────────────
# │ LESSON LEARNED: Some ArgoCD apps fail because they depend on CRDs
# │ that don't exist until their operator subscription installs.
# │ The SkipDryRunOnMissingResource annotation helps, but if the sync
# │ fails before ArgoCD reads it, we need to manually apply subscriptions.
# └─────────────────────────────────────────────────────────────────────────

log_info "Checking for stuck OutOfSync applications..."

# Get list of OutOfSync or failed apps
OUTOFSYNC_APPS=$(oc get applications.argoproj.io -n openshift-gitops --no-headers 2>/dev/null \
  | awk '$2 == "OutOfSync" || $3 == "Degraded" {print $1}' || true)

if [[ -n "$OUTOFSYNC_APPS" ]]; then
  log_info "Found OutOfSync/Degraded apps: $(echo $OUTOFSYNC_APPS | tr '\n' ' ')"

  # For each stuck app, check if it's a CRD dependency issue
  for APP in $OUTOFSYNC_APPS; do
    SYNC_MSG=$(oc get application.argoproj.io "$APP" -n openshift-gitops \
      -o jsonpath='{.status.operationState.message}' 2>/dev/null || echo "")

    if echo "$SYNC_MSG" | grep -q "CRD is installed\|no matches for kind\|synchronization tasks are not valid"; then
      log_warn "${APP}: CRD dependency issue — checking if operator is installed..."

      # Map app to operator namespace and subscription
      case "$APP" in
        gpu-operator)
          # Check if GPU operator subscription exists
          GPU_SUB=$(oc get subscription gpu-operator-certified -n gpu-operator-resources 2>/dev/null || echo "")
          if [[ -z "$GPU_SUB" ]]; then
            log_info "Creating GPU operator subscription..."
            oc apply -f "${GITOPS_DIR}/config/platform/gpu-operator-subscription.yaml" 2>/dev/null || true
          fi
          # Wait for CRD
          log_info "Waiting for ClusterPolicy CRD (up to 120s)..."
          for i in $(seq 1 12); do
            if oc get crd clusterpolicies.nvidia.com &>/dev/null; then
              log_ok "ClusterPolicy CRD available"
              # Now apply the CR
              oc apply -f "${GITOPS_DIR}/config/platform/gpu-clusterpolicy.yaml" 2>/dev/null || true
              break
            fi
            sleep 10
          done
          ;;
        nfd-operator)
          NFD_SUB=$(oc get subscription nfd -n openshift-nfd 2>/dev/null || echo "")
          if [[ -z "$NFD_SUB" ]]; then
            log_info "Creating NFD operator subscription..."
            oc apply -f "${GITOPS_DIR}/config/platform/nfd-subscription.yaml" 2>/dev/null || true
          fi
          log_info "Waiting for NodeFeatureDiscovery CRD (up to 120s)..."
          for i in $(seq 1 12); do
            if oc get crd nodefeaturediscoveries.nfd.openshift.io &>/dev/null; then
              log_ok "NodeFeatureDiscovery CRD available"
              oc apply -f "${GITOPS_DIR}/config/platform/nfd-instance.yaml" 2>/dev/null || true
              break
            fi
            sleep 10
          done
          ;;
        llama-inference|vllm-runtime)
          # These depend on KServe CRDs from RHOAI — check if RHOAI is ready
          RHOAI_PHASE=$(oc get csv -n redhat-ods-operator -l operators.coreos.com/rhods-operator.redhat-ods-operator \
            -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "unknown")
          if [[ "$RHOAI_PHASE" != "Succeeded" ]]; then
            log_warn "${APP}: RHOAI operator is '${RHOAI_PHASE}' — KServe CRDs not available yet. Will retry later."
          else
            log_info "${APP}: RHOAI is ready, force-syncing..."
            oc patch application.argoproj.io "$APP" -n openshift-gitops --type merge \
              -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{"revision":"HEAD"}}}' 2>/dev/null || true
          fi
          ;;
        *)
          # Generic: try force-sync
          log_info "Force-syncing ${APP}..."
          oc patch application.argoproj.io "$APP" -n openshift-gitops --type merge \
            -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{"revision":"HEAD"}}}' 2>/dev/null || true
          ;;
      esac
    else
      # Not a CRD issue — just force sync
      log_info "Force-syncing ${APP}..."
      oc patch application.argoproj.io "$APP" -n openshift-gitops --type merge \
        -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{"revision":"HEAD"}}}' 2>/dev/null || true
    fi
  done
else
  log_ok "No OutOfSync/Degraded apps found"
fi

# Step 8d: Wait for apps to converge
log_info "Waiting for ArgoCD applications to sync (timeout: ${ARGOCD_TIMEOUT}s)..."
MAX_WAIT=$ARGOCD_TIMEOUT
ELAPSED=0
# Track KServe-dependent apps separately (they may stay OutOfSync until RHOAI finishes)
KSERVE_APPS="llama-inference vllm-runtime"

while [[ $ELAPSED -lt $MAX_WAIT ]]; do
  TOTAL_APPS=$(oc get applications.argoproj.io -n openshift-gitops --no-headers 2>/dev/null | wc -l | tr -d ' ')
  HEALTHY_APPS=$(oc get applications.argoproj.io -n openshift-gitops --no-headers 2>/dev/null \
    | awk '{print $2, $3}' | grep -c "Synced.*Healthy" || echo "0")

  # Count KServe-dependent apps that are still OutOfSync (acceptable)
  KSERVE_OUTOFSYNC=0
  for KA in $KSERVE_APPS; do
    KA_STATUS=$(oc get application.argoproj.io "$KA" -n openshift-gitops -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "")
    [[ "$KA_STATUS" == "OutOfSync" ]] && KSERVE_OUTOFSYNC=$((KSERVE_OUTOFSYNC + 1))
  done

  # Also count Progressing apps (they're working, just not done)
  PROGRESSING_APPS=$(oc get applications.argoproj.io -n openshift-gitops --no-headers 2>/dev/null \
    | awk '{print $3}' | grep -c "Progressing" || echo "0")

  EFFECTIVE_HEALTHY=$((HEALTHY_APPS + KSERVE_OUTOFSYNC + PROGRESSING_APPS))

  if [[ "$EFFECTIVE_HEALTHY" -ge "$TOTAL_APPS" && "$TOTAL_APPS" -gt 0 ]]; then
    log_ok "All ${TOTAL_APPS} ArgoCD applications are converged"
    if [[ "$KSERVE_OUTOFSYNC" -gt 0 ]]; then
      log_warn "${KSERVE_OUTOFSYNC} KServe-dependent app(s) waiting for RHOAI to finish installing"
    fi
    break
  fi

  REMAINING=$((TOTAL_APPS - EFFECTIVE_HEALTHY))
  echo -e "     ${DIM}[${ELAPSED}s] ${HEALTHY_APPS}/${TOTAL_APPS} healthy, ${PROGRESSING_APPS} progressing, ${REMAINING} need attention...${RESET}"
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
  elif echo "$KSERVE_APPS" | grep -qw "$NAME"; then
    echo -e "    ${CYAN}⏳${RESET} ${NAME}  ${DIM}(${SYNC}/${HEALTH} — waiting for RHOAI/KServe CRDs)${RESET}"
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
echo -e "                        ${DIM}User: minioadmin  Pass: ${DEFAULT_PASSWORD}${RESET}"
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
echo -e "    Aurora DB         : ${DIM}ai-demo-ocp-db.cluster-cidweltunfq6.us-east-1.rds.amazonaws.com:5432${RESET}"
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
