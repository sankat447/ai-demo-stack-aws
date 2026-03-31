#!/usr/bin/env bash
# =============================================================================
#  AI Demo Stack — Power Down Masters
#  Stops master EC2 instances to minimize overnight/weekend costs.
#  WARNING: API will be completely unavailable until masters are restarted.
#
#  Prerequisites: Run drain-workers-aws-ocp.sh FIRST!
#
#  Usage: ./scripts/power-down-masters-aws-ocp.sh
#  Cost:  ~$7/day (NAT + Aurora + EFS/S3 only — no EC2)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

LOG_FILE="${LOG_DIR}/power-down-masters_${TIMESTAMP}.log"

echo ""
echo -e "${RED}${BOLD}╔══════════════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${RED}${BOLD}║        AI DEMO STACK — POWER DOWN MASTERS                            ║${RESET}"
echo -e "${RED}${BOLD}║        ⚠  API WILL BE COMPLETELY UNAVAILABLE                         ║${RESET}"
echo -e "${RED}${BOLD}╚══════════════════════════════════════════════════════════════════════╝${RESET}"

# ── Prerequisites ──────────────────────────────────────────────────────────
section "PHASE 1 — Authentication"

# Source reauth.sh for AWS SSO + KUBECONFIG
source "${SCRIPT_DIR}/reauth.sh"

# ── Safety check: ensure workers are already drained ──────────────────────
section "PHASE 2 — Safety Checks"

INFRA_ID=""
KUBECONFIG_PATH="${ENV_DIR}/ocp-install-dir/${CLUSTER_NAME}/auth/kubeconfig"

# Try to get infra ID from cluster if API is up
if [[ -f "$KUBECONFIG_PATH" ]]; then
  export KUBECONFIG="$KUBECONFIG_PATH"
  INFRA_ID=$(oc get infrastructure cluster -o jsonpath='{.status.infrastructureName}' 2>/dev/null || echo "")
fi

# Fallback: discover infra ID from EC2 tags
if [[ -z "$INFRA_ID" ]]; then
  log_info "Discovering infra ID from EC2 tags..."
  INFRA_ID=$(aws ec2 describe-instances --profile "$AWS_PROFILE" \
    --filters "Name=tag:Name,Values=${CLUSTER_NAME}-*-master-*" "Name=instance-state-name,Values=running" \
    --query 'Reservations[].Instances[].Tags[?Key==`Name`].Value | [0][0]' --output text 2>/dev/null \
    | sed -E 's/-(master|worker)-.*//' || echo "")
fi

if [[ -z "$INFRA_ID" || "$INFRA_ID" == "None" ]]; then
  abort "Cannot determine cluster infra ID. Are masters already stopped?"
fi
log_ok "Cluster infra ID: ${INFRA_ID}"

# Check for running workers
RUNNING_WORKERS=$(aws ec2 describe-instances --profile "$AWS_PROFILE" \
  --filters "Name=tag:Name,Values=*${INFRA_ID}*worker*" "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null || true)

if [[ -n "$RUNNING_WORKERS" && "$RUNNING_WORKERS" != "None" ]]; then
  log_fail "Workers are still running! Drain workers first."
  echo -e "     ${YELLOW}Run: ${CYAN}./scripts/drain-workers-aws-ocp.sh${RESET}"
  abort "Cannot power down masters while workers are running."
fi
log_ok "No running workers found — safe to proceed"

# ── Discover master instances ──────────────────────────────────────────────
section "PHASE 3 — Discover Master Instances"

MASTER_INSTANCES=$(aws ec2 describe-instances --profile "$AWS_PROFILE" \
  --filters "Name=tag:Name,Values=*${INFRA_ID}*master*" "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].[InstanceId,Tags[?Key==`Name`].Value|[0],InstanceType,Placement.AvailabilityZone]' \
  --output text 2>/dev/null || true)

if [[ -z "$MASTER_INSTANCES" || "$MASTER_INSTANCES" == "None" ]]; then
  log_warn "No running master instances found — already stopped?"
  print_summary
  exit 0
fi

echo ""
echo -e "  ${WHITE}Master Instances to Stop:${RESET}"
INSTANCE_IDS=()
while IFS=$'\t' read -r ID NAME TYPE AZ; do
  echo -e "    ${CYAN}${NAME}${RESET}  ${DIM}(${ID}, ${TYPE}, ${AZ})${RESET}"
  INSTANCE_IDS+=("$ID")
done <<< "$MASTER_INSTANCES"
echo ""

# ── Confirmation ───────────────────────────────────────────────────────────
if ! confirm "Stop ${#INSTANCE_IDS[@]} master instance(s)? The cluster API will be DOWN."; then
  log_warn "Aborted by user."
  print_summary
  exit 0
fi

# ── Stop master instances ──────────────────────────────────────────────────
section "PHASE 4 — Stopping Master EC2 Instances"

log_info "Sending stop command..."
aws ec2 stop-instances --profile "$AWS_PROFILE" --instance-ids "${INSTANCE_IDS[@]}" \
  --output json 2>/dev/null | python3 -c "
import sys, json
data = json.load(sys.stdin)
for inst in data.get('StoppingInstances', []):
    print(f\"  {inst['InstanceId']}: {inst['PreviousState']['Name']} → {inst['CurrentState']['Name']}\")
" 2>/dev/null || true

# ── Wait for instances to stop ─────────────────────────────────────────────
log_info "Waiting for instances to stop..."
MAX_WAIT=300
ELAPSED=0
INTERVAL=15

while [[ $ELAPSED -lt $MAX_WAIT ]]; do
  STILL_RUNNING=$(aws ec2 describe-instances --profile "$AWS_PROFILE" \
    --instance-ids "${INSTANCE_IDS[@]}" \
    --query 'Reservations[].Instances[?State.Name!=`stopped`].InstanceId' \
    --output text 2>/dev/null || true)

  if [[ -z "$STILL_RUNNING" || "$STILL_RUNNING" == "None" ]]; then
    log_ok "All master instances stopped."
    break
  fi

  echo -e "     ${DIM}[${ELAPSED}s] Waiting for instances to stop...${RESET}"
  sleep "$INTERVAL"
  ELAPSED=$((ELAPSED + INTERVAL))
done

if [[ $ELAPSED -ge $MAX_WAIT ]]; then
  log_warn "Timed out waiting — instances may still be stopping. Check AWS console."
fi

# ── Also check for bootstrap instance ──────────────────────────────────────
BOOTSTRAP=$(aws ec2 describe-instances --profile "$AWS_PROFILE" \
  --filters "Name=tag:Name,Values=*${INFRA_ID}*bootstrap*" "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null || true)

if [[ -n "$BOOTSTRAP" && "$BOOTSTRAP" != "None" ]]; then
  log_info "Found running bootstrap instance — terminating (no longer needed)..."
  aws ec2 terminate-instances --profile "$AWS_PROFILE" --instance-ids $BOOTSTRAP 2>/dev/null || true
  log_ok "Bootstrap instance terminated"
fi

# ── Final state ────────────────────────────────────────────────────────────
section "PHASE 5 — Final State"

echo ""
echo -e "  ${WHITE}EC2 Instance Summary:${RESET}"
aws ec2 describe-instances --profile "$AWS_PROFILE" \
  --filters "Name=tag:Name,Values=*${INFRA_ID}*" \
  --query 'Reservations[].Instances[].[Tags[?Key==`Name`].Value|[0],State.Name,InstanceType]' \
  --output text 2>/dev/null | while IFS=$'\t' read -r NAME STATE TYPE; do
    COLOR="${RED}"
    [[ "$STATE" == "stopped" ]] && COLOR="${YELLOW}"
    [[ "$STATE" == "running" ]] && COLOR="${GREEN}"
    echo -e "    ${COLOR}${NAME}${RESET}  ${DIM}${STATE} (${TYPE})${RESET}"
  done

echo ""
log_ok "Cluster fully powered down"
log_ok "Estimated cost: ~\$0.30/hr (~\$7/day) — NAT gateways + Aurora + storage only"

echo ""
echo -e "  ${YELLOW}${BOLD}💡 To bring everything back:${RESET}"
echo -e "     ${CYAN}./scripts/power-on-and-scaleup-aws-demo.sh${RESET}"

print_summary
