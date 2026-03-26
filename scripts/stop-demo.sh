#!/usr/bin/env bash
# =============================================================================
#  Scale down OCP worker pools to save costs overnight
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"
LOG_FILE="${LOG_DIR}/stop-demo_${TIMESTAMP}.log"

section "STOP DEMO: Scaling down workers"

KUBECONFIG_PATH="${ENV_DIR}/ocp-install-dir/${CLUSTER_NAME}/auth/kubeconfig"
if [[ -f "$KUBECONFIG_PATH" ]]; then
  export KUBECONFIG="$KUBECONFIG_PATH"

  # Scale compute MachineSets to 0
  for MS in $(oc get machinesets -n openshift-machine-api -o name 2>/dev/null | grep compute); do
    oc scale "$MS" -n openshift-machine-api --replicas=0
    log_ok "Scaled $(basename $MS) to 0 replicas"
  done

  # Scale initial workers to 0
  for MS in $(oc get machinesets -n openshift-machine-api -o name 2>/dev/null | grep worker); do
    oc scale "$MS" -n openshift-machine-api --replicas=0
    log_ok "Scaled $(basename $MS) to 0 replicas"
  done

  log_ok "Worker pools scaling down — saves ~\$30/day"
else
  log_fail "No kubeconfig found"
fi

print_summary
