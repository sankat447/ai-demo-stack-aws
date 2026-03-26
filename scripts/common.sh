#!/usr/bin/env bash
# =============================================================================
#  AI Demo Stack on AWS — Shared Utilities
#  Sourced by deploy.sh, destroy.sh, and all operational scripts.
# =============================================================================

# ── Colour palette ──────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
WHITE='\033[1;37m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

# ── Defaults ────────────────────────────────────────────────────────────────
DEFAULT_PASSWORD='Demo1234#'
AWS_PROFILE="${AWS_PROFILE:-rhoai-demo}"
AWS_REGION="${AWS_REGION:-us-east-1}"
CLUSTER_NAME="${CLUSTER_NAME:-ai-demo}"

# ── Paths ───────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${SCRIPT_DIR}/.."
ENV_DIR="${ROOT_DIR}/environments/demo"
GITOPS_DIR="${ROOT_DIR}/gitops"
TEMPLATES_DIR="${ROOT_DIR}/templates"
LOG_DIR="${ROOT_DIR}/logs"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")

mkdir -p "${LOG_DIR}"

# ── Step tracking ───────────────────────────────────────────────────────────
STEPS_PASSED=0
STEPS_FAILED=0
STEPS_WARNED=0
SUMMARY_LINES=()

# ── Logging helpers ─────────────────────────────────────────────────────────
log()       { echo -e "[$(date '+%H:%M:%S')] $*" | tee -a "${LOG_FILE:-/dev/null}"; }
log_ok()    { echo -e "  ${GREEN}✔${RESET}  ${GREEN}$*${RESET}" | tee -a "${LOG_FILE:-/dev/null}"; STEPS_PASSED=$((STEPS_PASSED+1)); SUMMARY_LINES+=("${GREEN}  ✔  $*${RESET}"); }
log_warn()  { echo -e "  ${YELLOW}⚠${RESET}  ${YELLOW}$*${RESET}" | tee -a "${LOG_FILE:-/dev/null}"; STEPS_WARNED=$((STEPS_WARNED+1)); SUMMARY_LINES+=("${YELLOW}  ⚠  $*${RESET}"); }
log_fail()  { echo -e "  ${RED}✘${RESET}  ${RED}$*${RESET}" | tee -a "${LOG_FILE:-/dev/null}"; STEPS_FAILED=$((STEPS_FAILED+1)); SUMMARY_LINES+=("${RED}  ✘  $*${RESET}"); }
log_info()  { echo -e "  ${BLUE}➤${RESET}  $*" | tee -a "${LOG_FILE:-/dev/null}"; }

section() {
  echo "" | tee -a "${LOG_FILE:-/dev/null}"
  echo -e "${CYAN}${BOLD}┌──────────────────────────────────────────────────────────────────────┐${RESET}" | tee -a "${LOG_FILE:-/dev/null}"
  printf "${CYAN}${BOLD}│  %-68s│${RESET}\n" "$1" | tee -a "${LOG_FILE:-/dev/null}"
  echo -e "${CYAN}${BOLD}└──────────────────────────────────────────────────────────────────────┘${RESET}" | tee -a "${LOG_FILE:-/dev/null}"
}

abort() {
  echo "" | tee -a "${LOG_FILE:-/dev/null}"
  echo -e "${RED}${BOLD}╔══ FATAL ERROR ══════════════════════════════════════════════════════════╗${RESET}" | tee -a "${LOG_FILE:-/dev/null}"
  echo -e "${RED}${BOLD}║  $1${RESET}" | tee -a "${LOG_FILE:-/dev/null}"
  echo -e "${RED}${BOLD}╚═════════════════════════════════════════════════════════════════════════╝${RESET}" | tee -a "${LOG_FILE:-/dev/null}"
  print_summary
  exit 1
}

confirm() {
  echo ""
  echo -e "${YELLOW}${BOLD}  ?  $1${RESET}"
  printf "     ${YELLOW}Enter [y/N]: ${RESET}"
  read -r _answer
  [[ "$_answer" =~ ^[Yy]$ ]]
}

print_summary() {
  echo ""
  echo -e "${WHITE}${BOLD}╔══════════════════════════════════════════════════════════════════════╗${RESET}"
  echo -e "${WHITE}${BOLD}║            AI DEMO STACK — RUN SUMMARY                              ║${RESET}"
  echo -e "${WHITE}${BOLD}╚══════════════════════════════════════════════════════════════════════╝${RESET}"
  echo ""
  for line in "${SUMMARY_LINES[@]}"; do echo -e "$line"; done
  echo ""
  echo -e "  ${GREEN}${BOLD}Passed : ${STEPS_PASSED}${RESET}     ${YELLOW}${BOLD}Warnings : ${STEPS_WARNED}${RESET}     ${RED}${BOLD}Failed : ${STEPS_FAILED}${RESET}"
  echo ""
  if [[ $STEPS_FAILED -eq 0 ]]; then
    echo -e "${GREEN}${BOLD}  ✔  All critical steps passed.${RESET}"
  else
    echo -e "${RED}${BOLD}  ✘  ${STEPS_FAILED} step(s) failed — review errors above.${RESET}"
  fi
  echo ""
  echo -e "${DIM}  Full log : ${LOG_FILE:-N/A}${RESET}"
  echo ""
}

# ── AWS SSO Authentication ──────────────────────────────────────────────────
aws_sso_login() {
  log_info "Checking AWS SSO session (profile: ${AWS_PROFILE})..."
  if aws sts get-caller-identity --profile "$AWS_PROFILE" &>/dev/null; then
    local ACCOUNT ARN
    ACCOUNT=$(aws sts get-caller-identity --profile "$AWS_PROFILE" --query Account --output text 2>/dev/null)
    ARN=$(aws sts get-caller-identity --profile "$AWS_PROFILE" --query Arn --output text 2>/dev/null)
    log_ok "AWS authenticated — Account: ${ACCOUNT}"
    echo -e "     ${DIM}Role: ${ARN}${RESET}"
  else
    log_warn "AWS SSO session expired — opening browser for login..."
    echo -e "     ${DIM}A browser window will open for AWS SSO. Complete login then return here.${RESET}"
    echo ""
    aws sso login --profile "$AWS_PROFILE" || abort "AWS SSO login failed. Verify profile '${AWS_PROFILE}' in ~/.aws/config"
    local ACCOUNT
    ACCOUNT=$(aws sts get-caller-identity --profile "$AWS_PROFILE" --query Account --output text 2>/dev/null)
    log_ok "AWS authenticated — Account: ${ACCOUNT}"
  fi
  export AWS_PROFILE
}

# ── Red Hat SSO Authentication ──────────────────────────────────────────────
redhat_sso_login() {
  log_info "Checking Red Hat OCM authentication..."
  local WHOAMI_OUT
  WHOAMI_OUT=$(rosa whoami 2>&1 || true)
  if echo "$WHOAMI_OUT" | grep -q "OCM Account Email"; then
    local OCM_EMAIL
    OCM_EMAIL=$(echo "$WHOAMI_OUT" | grep "OCM Account Email" | awk '{print $NF}')
    log_ok "OCM authenticated — ${OCM_EMAIL}"
  else
    log_warn "ROSA not authenticated — opening browser for Red Hat SSO login..."
    echo -e "     ${DIM}A browser window will open for Red Hat SSO. Complete login then return here.${RESET}"
    echo ""
    rosa login --use-auth-code || abort "Red Hat SSO login failed. Visit https://console.redhat.com"
    WHOAMI_OUT=$(rosa whoami 2>&1 || true)
    if echo "$WHOAMI_OUT" | grep -q "OCM Account Email"; then
      local OCM_EMAIL
      OCM_EMAIL=$(echo "$WHOAMI_OUT" | grep "OCM Account Email" | awk '{print $NF}')
      log_ok "OCM authenticated — ${OCM_EMAIL}"
    else
      abort "Red Hat SSO login failed — check https://console.redhat.com"
    fi
  fi
}

# ── OpenShift Login ─────────────────────────────────────────────────────────
ocp_login() {
  local API_URL="$1"
  local KUBECONFIG_PATH="$2"
  log_info "Logging into OpenShift cluster..."
  if [[ -f "$KUBECONFIG_PATH" ]]; then
    export KUBECONFIG="$KUBECONFIG_PATH"
    if oc whoami &>/dev/null; then
      log_ok "OCP authenticated as $(oc whoami)"
      return 0
    fi
  fi
  log_warn "Attempting OCP login with kubeadmin..."
  local KUBEADMIN_PASS
  KUBEADMIN_PASS=$(cat "${ENV_DIR}/ocp-install-dir/auth/kubeadmin-password" 2>/dev/null || echo "")
  if [[ -n "$KUBEADMIN_PASS" ]]; then
    oc login "$API_URL" -u kubeadmin -p "$KUBEADMIN_PASS" --insecure-skip-tls-verify=true || abort "OCP login failed"
    log_ok "OCP authenticated as kubeadmin"
  else
    abort "No kubeconfig or kubeadmin password found. Run deploy.sh first."
  fi
}

# ── Tool check ──────────────────────────────────────────────────────────────
check_required_tools() {
  local ABORT_MISSING=false
  for tool in "$@"; do
    if command -v "$tool" &>/dev/null; then
      local VER
      case "$tool" in
        rosa|oc) VER=$(timeout 5 "$tool" version 2>&1 | head -1 || echo "(version check timeout)") ;;
        openshift-install) VER=$(timeout 5 "$tool" version 2>&1 | head -1 || echo "(version check timeout)") ;;
        *) VER=$(timeout 5 "$tool" --version 2>&1 | head -1 || echo "(version check timeout)") ;;
      esac
      log_ok "$tool  →  $VER"
    else
      log_fail "$tool not found — install required"
      ABORT_MISSING=true
    fi
  done
  [[ "$ABORT_MISSING" == "true" ]] && abort "Missing required tools. See above."
}

# ── Wait for condition ──────────────────────────────────────────────────────
wait_for() {
  local DESCRIPTION="$1"
  local CHECK_CMD="$2"
  local TIMEOUT_SECS="${3:-600}"
  local INTERVAL="${4:-30}"

  log_info "Waiting for: ${DESCRIPTION} (timeout: ${TIMEOUT_SECS}s)..."
  local ELAPSED=0
  while [[ $ELAPSED -lt $TIMEOUT_SECS ]]; do
    if eval "$CHECK_CMD" &>/dev/null; then
      log_ok "${DESCRIPTION} — ready"
      return 0
    fi
    echo -e "     ${DIM}Waiting... (${ELAPSED}s / ${TIMEOUT_SECS}s)${RESET}"
    sleep "$INTERVAL"
    ELAPSED=$((ELAPSED + INTERVAL))
  done
  log_fail "${DESCRIPTION} — timed out after ${TIMEOUT_SECS}s"
  return 1
}
