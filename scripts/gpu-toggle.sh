#!/usr/bin/env bash
# =============================================================================
#  Toggle GPU worker pool on/off
#  Usage: ./scripts/gpu-toggle.sh on|off
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"
LOG_FILE="${LOG_DIR}/gpu-toggle_${TIMESTAMP}.log"

ACTION="${1:-status}"

KUBECONFIG_PATH="${ENV_DIR}/ocp-install-dir/${CLUSTER_NAME}/auth/kubeconfig"
if [[ ! -f "$KUBECONFIG_PATH" ]]; then
  abort "No kubeconfig found"
fi
export KUBECONFIG="$KUBECONFIG_PATH"

GPU_MS=$(oc get machinesets -n openshift-machine-api -o name 2>/dev/null | grep gpu | head -1)

if [[ -z "$GPU_MS" ]]; then
  abort "No GPU MachineSet found"
fi

case "$ACTION" in
  on)
    section "GPU: Enabling"
    oc scale "$GPU_MS" -n openshift-machine-api --replicas=1
    log_ok "GPU pool scaling to 1 (g4dn.xlarge with T4)"
    ;;
  off)
    section "GPU: Disabling"
    oc scale "$GPU_MS" -n openshift-machine-api --replicas=0
    log_ok "GPU pool scaled to 0"
    ;;
  *)
    REPLICAS=$(oc get "$GPU_MS" -n openshift-machine-api -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
    echo -e "GPU pool: ${REPLICAS} replicas"
    echo -e "Usage: $0 on|off"
    ;;
esac

print_summary
