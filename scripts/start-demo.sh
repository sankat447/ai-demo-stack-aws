#!/usr/bin/env bash
# =============================================================================
#  Scale up OCP worker pools for demo usage
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"
LOG_FILE="${LOG_DIR}/start-demo_${TIMESTAMP}.log"

section "START DEMO: Scaling up workers"

aws_sso_login

KUBECONFIG_PATH="${ENV_DIR}/ocp-install-dir/${CLUSTER_NAME}/auth/kubeconfig"
if [[ -f "$KUBECONFIG_PATH" ]]; then
  export KUBECONFIG="$KUBECONFIG_PATH"

  # Scale compute MachineSets
  for MS in $(oc get machinesets -n openshift-machine-api -o name 2>/dev/null | grep compute); do
    oc scale "$MS" -n openshift-machine-api --replicas=2
    log_ok "Scaled $(basename $MS) to 2 replicas"
  done

  # Scale initial worker MachineSets
  for MS in $(oc get machinesets -n openshift-machine-api -o name 2>/dev/null | grep worker); do
    oc scale "$MS" -n openshift-machine-api --replicas=1
    log_ok "Scaled $(basename $MS) to 1 replica"
  done

  log_ok "Worker pools scaling up — nodes will be ready in 5-8 minutes"
else
  log_fail "No kubeconfig found"
fi

print_summary
