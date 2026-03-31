#!/usr/bin/env bash
# =============================================================================
#  AI Demo Stack — Drain & Scale Down Workers
#  Gracefully drains all worker nodes and scales machinesets to 0.
#  Masters remain running so the API stays up.
#
#  Usage: ./scripts/drain-workers-aws-ocp.sh
#  Cost:  ~$21/day (masters + NAT + Aurora only)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

LOG_FILE="${LOG_DIR}/drain-workers_${TIMESTAMP}.log"

echo ""
echo -e "${MAGENTA}${BOLD}╔══════════════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${MAGENTA}${BOLD}║        AI DEMO STACK — DRAIN & SCALE DOWN WORKERS                   ║${RESET}"
echo -e "${MAGENTA}${BOLD}╚══════════════════════════════════════════════════════════════════════╝${RESET}"

# ── Prerequisites ──────────────────────────────────────────────────────────
section "PHASE 1 — Authentication & Cluster Connection"

# Source reauth.sh for AWS SSO + KUBECONFIG + OCP connectivity
source "${SCRIPT_DIR}/reauth.sh"

if ! oc whoami &>/dev/null; then
  abort "Cannot connect to OCP cluster. Check KUBECONFIG and network."
fi
log_ok "Connected to cluster as $(oc whoami)"

# ── Discover machinesets ───────────────────────────────────────────────────
section "PHASE 2 — Discover Worker MachineSets"

INFRA_ID=$(oc get infrastructure cluster -o jsonpath='{.status.infrastructureName}' 2>/dev/null || echo "unknown")
log_info "Cluster infra ID: ${INFRA_ID}"

MACHINESETS=$(oc get machinesets -n openshift-machine-api -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.replicas}{"\n"}{end}' | grep worker || true)

if [[ -z "$MACHINESETS" ]]; then
  log_warn "No worker machinesets found — workers may already be scaled down."
  print_summary
  exit 0
fi

echo ""
echo -e "  ${WHITE}Current Worker MachineSets:${RESET}"
while IFS=' ' read -r MS_NAME MS_REPLICAS; do
  echo -e "    ${CYAN}${MS_NAME}${RESET}  replicas: ${MS_REPLICAS}"
done <<< "$MACHINESETS"
echo ""

TOTAL_WORKERS=$(oc get machines -n openshift-machine-api --no-headers | grep -c worker || echo "0")
if [[ "$TOTAL_WORKERS" -eq 0 ]]; then
  log_warn "No worker machines running — nothing to drain."
  print_summary
  exit 0
fi
log_info "${TOTAL_WORKERS} worker machine(s) to drain and terminate."

# ── Scale machinesets to 0 ─────────────────────────────────────────────────
section "PHASE 3 — Scale Down Worker MachineSets"

while IFS=' ' read -r MS_NAME MS_REPLICAS; do
  if [[ "$MS_REPLICAS" -eq 0 ]]; then
    log_ok "${MS_NAME} already at 0 replicas"
    continue
  fi
  log_info "Scaling ${MS_NAME} from ${MS_REPLICAS} → 0..."
  oc scale machineset "$MS_NAME" -n openshift-machine-api --replicas=0
  log_ok "${MS_NAME} scaled to 0"
done <<< "$MACHINESETS"

# ── Wait for machines to delete (with timeout) ────────────────────────────
section "PHASE 4 — Wait for Workers to Terminate"

MAX_WAIT=600  # 10 minutes
ELAPSED=0
INTERVAL=15

while [[ $ELAPSED -lt $MAX_WAIT ]]; do
  REMAINING=$(oc get machines -n openshift-machine-api --no-headers 2>/dev/null | grep worker | wc -l | tr -d ' ')
  if [[ "$REMAINING" -eq 0 ]]; then
    log_ok "All worker machines deleted."
    break
  fi

  # Show current state
  echo -e "     ${DIM}[${ELAPSED}s] ${REMAINING} worker(s) still deleting...${RESET}"

  # Check for stuck machines (Deleting for > 3 minutes)
  STUCK_MACHINES=$(oc get machines -n openshift-machine-api --no-headers 2>/dev/null | grep worker | grep Deleting || true)
  if [[ -n "$STUCK_MACHINES" && $ELAPSED -gt 180 ]]; then
    log_warn "Machines stuck in Deleting — removing finalizers..."
    while read -r STUCK_LINE; do
      STUCK_NAME=$(echo "$STUCK_LINE" | awk '{print $1}')
      log_info "Removing finalizers from ${STUCK_NAME}..."
      oc patch machine "$STUCK_NAME" -n openshift-machine-api --type merge -p '{"metadata":{"finalizers":null}}' 2>/dev/null || true
    done <<< "$STUCK_MACHINES"
  fi

  sleep "$INTERVAL"
  ELAPSED=$((ELAPSED + INTERVAL))
done

# ── Force terminate any remaining EC2 instances ────────────────────────────
REMAINING_EC2=$(aws ec2 describe-instances --profile "$AWS_PROFILE" \
  --filters "Name=tag:Name,Values=*${INFRA_ID}*worker*" "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null || true)

if [[ -n "$REMAINING_EC2" && "$REMAINING_EC2" != "None" ]]; then
  log_warn "Force terminating remaining worker EC2 instances..."
  aws ec2 terminate-instances --profile "$AWS_PROFILE" --instance-ids $REMAINING_EC2 2>/dev/null
  log_ok "EC2 terminate command sent for: ${REMAINING_EC2}"

  # Clean up any remaining machine objects
  for M in $(oc get machines -n openshift-machine-api --no-headers 2>/dev/null | grep worker | awk '{print $1}'); do
    oc patch machine "$M" -n openshift-machine-api --type merge -p '{"metadata":{"finalizers":null}}' 2>/dev/null || true
  done
fi

# ── Clean up stale node objects ────────────────────────────────────────────
section "PHASE 5 — Clean Up Stale Node Objects"

STALE_NODES=$(oc get nodes --no-headers 2>/dev/null | grep -E "worker|SchedulingDisabled" | grep -v "control-plane" | awk '{print $1}' || true)
if [[ -n "$STALE_NODES" ]]; then
  while read -r NODE; do
    log_info "Deleting stale node: ${NODE}"
    oc delete node "$NODE" --ignore-not-found 2>/dev/null || true
    log_ok "Node ${NODE} removed"
  done <<< "$STALE_NODES"
else
  log_ok "No stale worker nodes to clean up"
fi

# ── Verify final state ────────────────────────────────────────────────────
section "PHASE 6 — Final Verification"

echo ""
echo -e "  ${WHITE}Remaining Machines:${RESET}"
oc get machines -n openshift-machine-api --no-headers 2>/dev/null | while read -r line; do
  echo -e "    ${GREEN}${line}${RESET}"
done

echo ""
echo -e "  ${WHITE}Remaining Nodes:${RESET}"
oc get nodes --no-headers 2>/dev/null | while read -r line; do
  echo -e "    ${GREEN}${line}${RESET}"
done

echo ""
MASTER_COUNT=$(oc get machines -n openshift-machine-api --no-headers 2>/dev/null | grep master | wc -l | tr -d ' ')
WORKER_COUNT=$(oc get machines -n openshift-machine-api --no-headers 2>/dev/null | grep worker | wc -l | tr -d ' ')

if [[ "$WORKER_COUNT" -eq 0 && "$MASTER_COUNT" -eq 3 ]]; then
  log_ok "Cluster scaled down: ${MASTER_COUNT} masters, 0 workers"
  log_ok "Estimated cost: ~\$0.86/hr (~\$21/day)"
else
  log_warn "Unexpected state: ${MASTER_COUNT} masters, ${WORKER_COUNT} workers"
fi

echo ""
echo -e "  ${YELLOW}${BOLD}💡 Next steps:${RESET}"
echo -e "     ${DIM}• To also stop masters (saves ~\$14/day more):${RESET}"
echo -e "       ${CYAN}./scripts/power-down-masters-aws-ocp.sh${RESET}"
echo -e "     ${DIM}• To bring everything back up:${RESET}"
echo -e "       ${CYAN}./scripts/power-on-and-scaleup-aws-demo.sh${RESET}"

print_summary
