#!/usr/bin/env bash
# =============================================================================
#  AI Demo Stack — Re-authenticate & Set Environment
#  Sources AWS SSO, sets KUBECONFIG, and exports all required variables.
#
#  Usage: source ./scripts/reauth.sh
#         (MUST be sourced, not executed, so env vars persist in your shell)
#
#  What it does:
#    1. Logs into AWS SSO (opens browser if session expired)
#    2. Exports AWS_PROFILE and AWS_DEFAULT_REGION
#    3. Sets KUBECONFIG to the OCP cluster auth
#    4. Verifies OCP API connectivity
#    5. Unsets any stale AWS env vars from previous sessions
# =============================================================================

# ── Colour palette ──────────────────────────────────────────────────────────
_RED='\033[0;31m'
_GREEN='\033[0;32m'
_YELLOW='\033[1;33m'
_CYAN='\033[0;36m'
_DIM='\033[2m'
_BOLD='\033[1m'
_RESET='\033[0m'

_ok()   { echo -e "  ${_GREEN}✔${_RESET}  $*"; }
_warn() { echo -e "  ${_YELLOW}⚠${_RESET}  $*"; }
_fail() { echo -e "  ${_RED}✘${_RESET}  $*"; }
_info() { echo -e "  ${_CYAN}➤${_RESET}  $*"; }

echo ""
echo -e "${_CYAN}${_BOLD}┌──────────────────────────────────────────────────────────────────────┐${_RESET}"
echo -e "${_CYAN}${_BOLD}│  AI DEMO STACK — Re-authenticate & Set Environment                  │${_RESET}"
echo -e "${_CYAN}${_BOLD}└──────────────────────────────────────────────────────────────────────┘${_RESET}"

# ── Configuration ──────────────────────────────────────────────────────────
export AWS_PROFILE="${AWS_PROFILE:-rhoai-demo}"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
CLUSTER_NAME="${CLUSTER_NAME:-ai-demo}"

# Resolve paths relative to this script
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_ROOT_DIR="${_SCRIPT_DIR}/.."
_ENV_DIR="${_ROOT_DIR}/environments/demo"
_KUBECONFIG_PATH="${_ENV_DIR}/ocp-install-dir/${CLUSTER_NAME}/auth/kubeconfig"

# ── Step 1: Clear stale AWS credentials ────────────────────────────────────
_info "Clearing stale AWS env vars..."
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_CREDENTIAL_EXPIRATION 2>/dev/null || true
_ok "Stale env vars cleared"

# ── Step 2: AWS SSO Login ──────────────────────────────────────────────────
_info "Checking AWS SSO session (profile: ${AWS_PROFILE})..."
if aws sts get-caller-identity --profile "$AWS_PROFILE" &>/dev/null; then
  _ACCOUNT=$(aws sts get-caller-identity --profile "$AWS_PROFILE" --query Account --output text 2>/dev/null)
  _ARN=$(aws sts get-caller-identity --profile "$AWS_PROFILE" --query Arn --output text 2>/dev/null)
  _ok "AWS authenticated — Account: ${_ACCOUNT}"
  echo -e "     ${_DIM}Role: ${_ARN}${_RESET}"
else
  _warn "AWS SSO session expired — opening browser..."
  aws sso login --profile "$AWS_PROFILE"
  if aws sts get-caller-identity --profile "$AWS_PROFILE" &>/dev/null; then
    _ACCOUNT=$(aws sts get-caller-identity --profile "$AWS_PROFILE" --query Account --output text 2>/dev/null)
    _ok "AWS authenticated — Account: ${_ACCOUNT}"
  else
    _fail "AWS SSO login failed. Check profile '${AWS_PROFILE}' in ~/.aws/config"
    return 1 2>/dev/null || exit 1
  fi
fi

# ── Step 3: Set KUBECONFIG ─────────────────────────────────────────────────
_info "Setting KUBECONFIG..."
if [[ -f "$_KUBECONFIG_PATH" ]]; then
  export KUBECONFIG="$_KUBECONFIG_PATH"
  _ok "KUBECONFIG=${KUBECONFIG}"
else
  _warn "KUBECONFIG not found at ${_KUBECONFIG_PATH}"
  _warn "OCP cluster may not be installed yet. Run deploy.sh first."
fi

# ── Step 4: Verify OCP connectivity ────────────────────────────────────────
if [[ -f "$_KUBECONFIG_PATH" ]]; then
  _info "Checking OCP API connectivity..."
  if oc whoami &>/dev/null; then
    _OCP_USER=$(oc whoami 2>/dev/null)
    _OCP_VERSION=$(oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null || echo "unknown")
    _ok "OCP connected — user: ${_OCP_USER}, version: ${_OCP_VERSION}"
  else
    _warn "OCP API not reachable — masters may be stopped"
    echo -e "     ${_DIM}Run: ./scripts/power-on-and-scaleup-aws-demo.sh${_RESET}"
  fi
fi

# ── Step 5: Red Hat OCM check ──────────────────────────────────────────────
_info "Checking Red Hat OCM..."
if command -v rosa &>/dev/null; then
  _WHOAMI=$(rosa whoami 2>&1 || true)
  if echo "$_WHOAMI" | grep -q "OCM Account Email"; then
    _OCM_EMAIL=$(echo "$_WHOAMI" | grep "OCM Account Email" | awk '{print $NF}')
    _ok "OCM authenticated — ${_OCM_EMAIL}"
  else
    _warn "OCM not authenticated — run 'rosa login --use-auth-code' if needed"
  fi
else
  _info "rosa CLI not found — skipping OCM check"
fi

# ── Summary ────────────────────────────────────────────────────────────────
echo ""
echo -e "  ${_CYAN}${_BOLD}Environment Ready:${_RESET}"
echo -e "    AWS_PROFILE       = ${_GREEN}${AWS_PROFILE}${_RESET}"
echo -e "    AWS_DEFAULT_REGION= ${_GREEN}${AWS_DEFAULT_REGION}${_RESET}"
echo -e "    KUBECONFIG        = ${_GREEN}${KUBECONFIG:-not set}${_RESET}"
echo -e "    CLUSTER_NAME      = ${_GREEN}${CLUSTER_NAME}${_RESET}"
echo ""

# Clean up internal variables
unset _SCRIPT_DIR _ROOT_DIR _ENV_DIR _KUBECONFIG_PATH _ACCOUNT _ARN _OCP_USER _OCP_VERSION _WHOAMI _OCM_EMAIL
unset _RED _GREEN _YELLOW _CYAN _DIM _BOLD _RESET
unset -f _ok _warn _fail _info
