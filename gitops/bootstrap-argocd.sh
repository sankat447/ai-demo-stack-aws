#!/usr/bin/env bash
# =============================================================================
#  Bootstrap ArgoCD (OpenShift GitOps) and seed the App-of-Apps
#  Handles: operator install, repo auth (GitHub token), admin password,
#           cluster-admin grant, app-of-apps deployment
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${SCRIPT_DIR}/.."
source "${ROOT_DIR}/scripts/common.sh"

GITOPS_REPO_URL="https://github.com/sankat447/ai-demo-stack-aws"

# =============================================================================
section "BOOTSTRAP: Install OpenShift GitOps Operator"
# =============================================================================

cat <<'EOF' | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-gitops-operator
  namespace: openshift-operators
spec:
  channel: latest
  installPlanApproval: Automatic
  name: openshift-gitops-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
log_ok "GitOps operator subscription created"

# Wait for operator CSV
wait_for "GitOps operator CSV ready" \
  "oc get csv -n openshift-operators -o jsonpath='{.items[?(@.spec.displayName==\"Red Hat OpenShift GitOps\")].status.phase}' | grep -q Succeeded" \
  300 15

# Wait for ArgoCD server deployment
wait_for "ArgoCD server ready" \
  "oc get deployment openshift-gitops-server -n openshift-gitops -o jsonpath='{.status.readyReplicas}' | grep -q '[1-9]'" \
  300 15

log_ok "ArgoCD is running"

# =============================================================================
section "BOOTSTRAP: Configure GitHub Repo Access for ArgoCD"
# =============================================================================

# Even public repos need a PAT to avoid:
#   1. GitHub API rate limiting (60 req/hr anonymous vs 5000 authenticated)
#   2. ArgoCD repo-server auth caching failures on initial sync
# This matches the pattern from rhoai-gitops bootstrap v3.0

GITHUB_TOKEN=""
GITHUB_USER="sankat447"

# Auto-detect token from gh CLI (most common on macOS)
if command -v gh &>/dev/null && gh auth status &>/dev/null 2>&1; then
  GITHUB_TOKEN=$(gh auth token 2>/dev/null || echo "")
  if [[ -n "$GITHUB_TOKEN" ]]; then
    GITHUB_USER=$(gh api user --jq '.login' 2>/dev/null || echo "sankat447")
    log_ok "GitHub token auto-detected from gh CLI (user: ${GITHUB_USER})"
  fi
fi

# Fallback: environment variable
if [[ -z "$GITHUB_TOKEN" ]]; then
  GITHUB_TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-${GITHUB_PAT:-}}}"
  [[ -n "$GITHUB_TOKEN" ]] && log_ok "GitHub token found in environment variable"
fi

# Fallback: prompt
if [[ -z "$GITHUB_TOKEN" ]]; then
  log_warn "No GitHub token found automatically."
  echo ""
  echo -e "  ${YELLOW}ArgoCD needs a GitHub PAT even for public repos (rate limiting + auth caching).${RESET}"
  echo -e "  ${DIM}Create one at: https://github.com/settings/tokens → 'repo' scope (read only)${RESET}"
  echo ""
  printf "  GitHub Personal Access Token: "
  read -rs GITHUB_TOKEN
  echo ""
fi

if [[ -z "$GITHUB_TOKEN" ]]; then
  log_warn "No token provided — ArgoCD may hit rate limits or auth cache issues"
  log_warn "If sync fails, run: gh auth login && re-run this script"
else
  log_info "Creating ArgoCD repo secret for ${GITOPS_REPO_URL}..."

  oc apply -f - <<REPOSECRET
apiVersion: v1
kind: Secret
metadata:
  name: ai-demo-stack-repo
  namespace: openshift-gitops
  labels:
    argocd.argoproj.io/secret-type: repository
type: Opaque
stringData:
  type: git
  url: "${GITOPS_REPO_URL}"
  username: "${GITHUB_USER}"
  password: "${GITHUB_TOKEN}"
REPOSECRET

  log_ok "ArgoCD repo secret created (ai-demo-stack-repo)"

  # Restart repo-server to clear any cached auth failures
  log_info "Restarting ArgoCD repo-server to apply credentials..."
  oc rollout restart deployment/openshift-gitops-repo-server -n openshift-gitops
  oc rollout status deployment/openshift-gitops-repo-server -n openshift-gitops --timeout=120s \
    && log_ok "ArgoCD repo-server restarted" \
    || log_warn "repo-server restart timed out — may need manual check"
fi

# =============================================================================
section "BOOTSTRAP: Configure ArgoCD Admin"
# =============================================================================

# Set admin password
ARGOCD_PASS_HASH=$(python3 -c "import bcrypt; print(bcrypt.hashpw(b'${DEFAULT_PASSWORD}', bcrypt.gensalt()).decode())" 2>/dev/null || echo "")
if [[ -n "$ARGOCD_PASS_HASH" ]]; then
  oc -n openshift-gitops patch secret openshift-gitops-cluster \
    -p "{\"stringData\": {\"admin.password\": \"${ARGOCD_PASS_HASH}\"}}" 2>/dev/null || true
  log_ok "ArgoCD admin password set to: ${DEFAULT_PASSWORD}"
else
  log_warn "Could not hash password (pip3 install bcrypt) — using auto-generated password"
  ARGOCD_AUTO_PASS=$(oc get secret openshift-gitops-cluster -n openshift-gitops -o jsonpath='{.data.admin\.password}' 2>/dev/null | base64 -d || echo "check-secret")
  echo -e "     ${DIM}ArgoCD admin password: ${ARGOCD_AUTO_PASS}${RESET}"
fi

# Grant cluster-admin
oc adm policy add-cluster-role-to-user cluster-admin \
  system:serviceaccount:openshift-gitops:openshift-gitops-argocd-application-controller 2>/dev/null || true
log_ok "ArgoCD application controller has cluster-admin"

# =============================================================================
section "BOOTSTRAP: Deploy App-of-Apps (28 applications, 7 sync waves)"
# =============================================================================

oc apply -f "${SCRIPT_DIR}/apps/applications.yaml"
log_ok "App-of-Apps applied — ArgoCD will now sync all applications"

# Show ArgoCD URL
ARGOCD_ROUTE=$(oc get route openshift-gitops-server -n openshift-gitops -o jsonpath='{.spec.host}' 2>/dev/null || echo "pending")
echo ""
echo -e "${GREEN}${BOLD}ArgoCD Dashboard: https://${ARGOCD_ROUTE}${RESET}"
echo -e "${DIM}  Username: admin${RESET}"
echo -e "${DIM}  Password: ${DEFAULT_PASSWORD}${RESET}"
echo ""

log_ok "GitOps bootstrap complete — sync waves deploying..."
