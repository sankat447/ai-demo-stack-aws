#!/usr/bin/env bash
# =============================================================================
#  AI Demo Stack on AWS — Fully Automatic Deployment
#
#  Usage   : ./deploy.sh
#  What    : Registers domain, provisions AWS infra, installs OCP 4.20,
#            bootstraps ArgoCD + 28 apps, runs quality check.
#  Duration: ~45-60 minutes
#
#  ZERO manual config needed — script handles everything interactively.
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/scripts/common.sh"

LOG_FILE="${LOG_DIR}/deploy_${TIMESTAMP}.log"

# ── Banner ──────────────────────────────────────────────────────────────────
clear 2>/dev/null || true
echo ""
echo -e "${BLUE}${BOLD}╔══════════════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${BLUE}${BOLD}║                                                                      ║${RESET}"
echo -e "${BLUE}${BOLD}║   ${WHITE}${BOLD}  █████╗ ██╗    ██████╗ ███████╗███╗   ███╗ ██████╗              ${RESET}${BLUE}${BOLD}║${RESET}"
echo -e "${BLUE}${BOLD}║   ${WHITE}${BOLD} ██╔══██╗██║    ██╔══██╗██╔════╝████╗ ████║██╔═══██╗             ${RESET}${BLUE}${BOLD}║${RESET}"
echo -e "${BLUE}${BOLD}║   ${WHITE}${BOLD} ███████║██║    ██║  ██║█████╗  ██╔████╔██║██║   ██║             ${RESET}${BLUE}${BOLD}║${RESET}"
echo -e "${BLUE}${BOLD}║   ${WHITE}${BOLD} ██╔══██║██║    ██║  ██║██╔══╝  ██║╚██╔╝██║██║   ██║             ${RESET}${BLUE}${BOLD}║${RESET}"
echo -e "${BLUE}${BOLD}║   ${WHITE}${BOLD} ██║  ██║██║    ██████╔╝███████╗██║ ╚═╝ ██║╚██████╔╝             ${RESET}${BLUE}${BOLD}║${RESET}"
echo -e "${BLUE}${BOLD}║   ${WHITE}${BOLD} ╚═╝  ╚═╝╚═╝    ╚═════╝ ╚══════╝╚═╝     ╚═╝ ╚═════╝              ${RESET}${BLUE}${BOLD}║${RESET}"
echo -e "${BLUE}${BOLD}║                                                                      ║${RESET}"
echo -e "${BLUE}${BOLD}║   ${CYAN}AI Demo Stack on AWS — Full Stack Provisioning${RESET}${BLUE}${BOLD}                     ║${RESET}"
echo -e "${BLUE}${BOLD}║                                                                      ║${RESET}"
echo -e "${BLUE}${BOLD}║   ${DIM}  ✦  AWS: VPC · Aurora 16.4+pgvector · EFS · S3 · ECR · Lambda${RESET}${BLUE}${BOLD}  ║${RESET}"
echo -e "${BLUE}${BOLD}║   ${DIM}  ✦  OCP 4.20 IPI (3 masters + worker pools + T4 GPU)${RESET}${BLUE}${BOLD}           ║${RESET}"
echo -e "${BLUE}${BOLD}║   ${DIM}  ✦  GitOps: ArgoCD + 28 apps (RHOAI, KServe, vLLM...)${RESET}${BLUE}${BOLD}         ║${RESET}"
echo -e "${BLUE}${BOLD}║   ${DIM}  ✦  Domain auto-registered via Route53 (~\$3/yr)${RESET}${BLUE}${BOLD}               ║${RESET}"
echo -e "${BLUE}${BOLD}║                                                                      ║${RESET}"
echo -e "${BLUE}${BOLD}║   ${GREEN}Duration: ~45-60 minutes${RESET}${BLUE}${BOLD}                                          ║${RESET}"
echo -e "${BLUE}${BOLD}║   ${DIM}Run: ${TIMESTAMP}${RESET}${BLUE}${BOLD}                                    ║${RESET}"
echo -e "${BLUE}${BOLD}╚══════════════════════════════════════════════════════════════════════╝${RESET}"
echo ""
log "Log file: ${LOG_FILE}"

# =============================================================================
section "PHASE 0.1 — REQUIRED TOOLS CHECK"
# =============================================================================

check_required_tools aws terraform oc openshift-install git jq

# =============================================================================
section "PHASE 0.2 — AWS SSO AUTHENTICATION"
# =============================================================================

aws_sso_login

# =============================================================================
section "PHASE 0.3 — RED HAT SSO AUTHENTICATION"
# =============================================================================

redhat_sso_login

# =============================================================================
section "PHASE 0.4 — AUTO-CONFIGURE (domain, pull secret, tfvars)"
# =============================================================================

DOMAIN="iisdemolab.click"
CLUSTER="ai-demo"
TFVARS_FILE="${ENV_DIR}/terraform.tfvars"
PULL_SECRET_FILE="${ROOT_DIR}/.pull-secret.json"

# ── 0.4a: Domain Registration ──────────────────────────────────────────────
log_info "Checking domain ${DOMAIN} in Route53..."
ZONE_EXISTS=$(aws route53 list-hosted-zones-by-name --dns-name "${DOMAIN}" --profile "$AWS_PROFILE" --query "HostedZones[?Name=='${DOMAIN}.'].Id" --output text 2>/dev/null || echo "")

if [[ -n "$ZONE_EXISTS" ]]; then
  log_ok "Route53 hosted zone exists for ${DOMAIN}"
else
  # Check if domain is registered
  DOMAIN_STATUS=$(aws route53domains get-domain-detail --domain-name "${DOMAIN}" --profile "$AWS_PROFILE" --query "DomainName" --output text 2>/dev/null || echo "NOT_FOUND")

  if [[ "$DOMAIN_STATUS" == "NOT_FOUND" || "$DOMAIN_STATUS" == "None" ]]; then
    log_info "Domain ${DOMAIN} not yet registered."
    echo ""
    echo -e "  ${YELLOW}The deploy needs a domain for OCP cluster DNS.${RESET}"
    echo -e "  ${YELLOW}Route53 can register '${DOMAIN}' for ~\$3/year.${RESET}"
    echo ""

    if confirm "Register '${DOMAIN}' via Route53 now? (~\$3/yr, charged to your AWS account)"; then
      log_info "Registering ${DOMAIN} via Route53..."

      # Get AWS account contact info for domain registration
      ACCOUNT_EMAIL=$(aws sts get-caller-identity --profile "$AWS_PROFILE" --query "Arn" --output text 2>/dev/null | sed 's|.*:||')

      aws route53domains register-domain \
        --domain-name "${DOMAIN}" \
        --duration-in-years 1 \
        --auto-renew \
        --admin-contact '{
          "FirstName": "AI",
          "LastName": "Demo",
          "ContactType": "COMPANY",
          "OrganizationName": "IIS Tech",
          "Email": "skumar@iisl.com",
          "PhoneNumber": "+1.0000000000",
          "AddressLine1": "123 Demo Street",
          "City": "New York",
          "State": "NY",
          "CountryCode": "US",
          "ZipCode": "10001"
        }' \
        --registrant-contact '{
          "FirstName": "AI",
          "LastName": "Demo",
          "ContactType": "COMPANY",
          "OrganizationName": "IIS Tech",
          "Email": "skumar@iisl.com",
          "PhoneNumber": "+1.0000000000",
          "AddressLine1": "123 Demo Street",
          "City": "New York",
          "State": "NY",
          "CountryCode": "US",
          "ZipCode": "10001"
        }' \
        --tech-contact '{
          "FirstName": "AI",
          "LastName": "Demo",
          "ContactType": "COMPANY",
          "OrganizationName": "IIS Tech",
          "Email": "skumar@iisl.com",
          "PhoneNumber": "+1.0000000000",
          "AddressLine1": "123 Demo Street",
          "City": "New York",
          "State": "NY",
          "CountryCode": "US",
          "ZipCode": "10001"
        }' \
        --privacy-protect-admin-contact \
        --privacy-protect-registrant-contact \
        --privacy-protect-tech-contact \
        --profile "$AWS_PROFILE" 2>&1 | tee -a "${LOG_FILE}"

      if [[ ${PIPESTATUS[0]} -eq 0 ]]; then
        log_ok "Domain registration initiated for ${DOMAIN}"
        log_info "Route53 auto-creates the hosted zone. May take 1-15 minutes to propagate."

        # Wait for hosted zone to appear
        for i in $(seq 1 30); do
          ZONE_EXISTS=$(aws route53 list-hosted-zones-by-name --dns-name "${DOMAIN}" --profile "$AWS_PROFILE" --query "HostedZones[?Name=='${DOMAIN}.'].Id" --output text 2>/dev/null || echo "")
          if [[ -n "$ZONE_EXISTS" ]]; then
            log_ok "Hosted zone ready: ${ZONE_EXISTS}"
            break
          fi
          echo -e "     ${DIM}Waiting for DNS zone... (${i}/30)${RESET}"
          sleep 30
        done
      else
        log_warn "Domain registration may have failed — check Route53 console"
        log_info "You can also register manually: AWS Console → Route53 → Register Domain"
      fi
    else
      echo ""
      echo -e "  ${CYAN}You can use any domain you own. Edit base_domain in terraform.tfvars.${RESET}"
      printf "  Enter your domain (or press Enter for ${DOMAIN}): "
      read -r CUSTOM_DOMAIN
      if [[ -n "$CUSTOM_DOMAIN" ]]; then
        DOMAIN="$CUSTOM_DOMAIN"
        log_ok "Using domain: ${DOMAIN}"
      fi
    fi
  else
    log_ok "Domain ${DOMAIN} is registered — checking hosted zone..."
    # Domain registered but zone may not exist yet (terraform will create it)
  fi
fi

# ── 0.4b: Pull Secret ──────────────────────────────────────────────────────
if [[ -f "$PULL_SECRET_FILE" ]]; then
  log_ok "Pull secret found at ${PULL_SECRET_FILE}"
  PULL_SECRET=$(cat "$PULL_SECRET_FILE")
elif [[ -f "${HOME}/.pull-secret.json" ]]; then
  log_ok "Pull secret found at ~/.pull-secret.json"
  PULL_SECRET=$(cat "${HOME}/.pull-secret.json")
  cp "${HOME}/.pull-secret.json" "$PULL_SECRET_FILE"
else
  log_info "Red Hat pull secret needed for OCP installation."
  echo ""
  echo -e "  ${YELLOW}Opening browser to download your pull secret...${RESET}"
  echo -e "  ${DIM}https://console.redhat.com/openshift/install/pull-secret${RESET}"
  echo ""

  # Try to open browser
  open "https://console.redhat.com/openshift/install/pull-secret" 2>/dev/null || \
  xdg-open "https://console.redhat.com/openshift/install/pull-secret" 2>/dev/null || \
  echo -e "  ${YELLOW}Open this URL in your browser: https://console.redhat.com/openshift/install/pull-secret${RESET}"

  echo ""
  echo -e "  ${CYAN}Click 'Copy' on the pull secret page, then paste below.${RESET}"
  echo -e "  ${DIM}(The secret is a single long JSON line starting with {\"auths\":...)${RESET}"
  echo ""
  printf "  Paste pull secret: "
  read -r PULL_SECRET

  if [[ -z "$PULL_SECRET" || ! "$PULL_SECRET" == *"auths"* ]]; then
    abort "Invalid pull secret. Must be JSON containing 'auths'. Get it from:\nhttps://console.redhat.com/openshift/install/pull-secret"
  fi

  # Save for future runs
  echo "$PULL_SECRET" > "$PULL_SECRET_FILE"
  chmod 600 "$PULL_SECRET_FILE"
  log_ok "Pull secret saved to ${PULL_SECRET_FILE} (reused on future deploys)"
fi

# ── 0.4c: SSH Key (optional, auto-detect) ──────────────────────────────────
SSH_KEY=""
for KEY_FILE in ~/.ssh/id_ed25519.pub ~/.ssh/id_rsa.pub; do
  if [[ -f "$KEY_FILE" ]]; then
    SSH_KEY=$(cat "$KEY_FILE")
    log_ok "SSH key auto-detected: ${KEY_FILE}"
    break
  fi
done
[[ -z "$SSH_KEY" ]] && log_warn "No SSH key found — node debug access disabled (not required)"

# ── 0.4d: Auto-generate terraform.tfvars ───────────────────────────────────
log_info "Generating terraform.tfvars..."

cat > "${TFVARS_FILE}" << TFVARS
# =============================================================================
#  Auto-generated by deploy.sh at ${TIMESTAMP}
#  All defaults are production-ready. No manual edits needed.
# =============================================================================

# ── Project ──────────────────────────────────────────────────────────────────
project_name      = "rhoai-demo"
environment       = "demo"
owner_tag         = "skumar@iisl.com"
aws_region        = "us-east-1"
aws_profile       = "${AWS_PROFILE}"

# ── OCP Cluster ──────────────────────────────────────────────────────────────
cluster_name      = "${CLUSTER}"
base_domain       = "${DOMAIN}"
ocp_version       = "4.20.17"

# ── Compute ──────────────────────────────────────────────────────────────────
master_instance_type         = "m5.xlarge"
master_count                 = 3
initial_worker_instance_type = "m5.xlarge"
initial_worker_count         = 2
compute_instance_type        = "c5.2xlarge"
compute_min_replicas         = 1
compute_max_replicas         = 4
gpu_instance_type            = "g4dn.xlarge"
gpu_max_replicas             = 1

# ── Aurora ───────────────────────────────────────────────────────────────────
db_name               = "rhoai_demo"
db_master_username    = "rhoai_admin"
db_master_password    = "${DEFAULT_PASSWORD}"
aurora_engine_version = "16.4"
aurora_min_acu        = 0.5
aurora_max_acu        = 4

# ── Automation ───────────────────────────────────────────────────────────────
budget_alert_email = "skumar@iisl.com"
monthly_budget_usd = 700

# ── Auth ─────────────────────────────────────────────────────────────────────
admin_password = "${DEFAULT_PASSWORD}"

pull_secret = <<-PULLSECRET
${PULL_SECRET}
PULLSECRET

ssh_public_key = "${SSH_KEY}"
TFVARS

chmod 600 "${TFVARS_FILE}"
log_ok "terraform.tfvars generated (domain: ${DOMAIN}, cluster: ${CLUSTER})"

# ── Show what will be deployed ──────────────────────────────────────────────
echo ""
echo -e "  ${CYAN}Configuration Summary:${RESET}"
echo -e "  ${DIM}  Domain:    ${DOMAIN}${RESET}"
echo -e "  ${DIM}  Cluster:   ${CLUSTER}.${DOMAIN}${RESET}"
echo -e "  ${DIM}  Console:   https://console-openshift-console.apps.${CLUSTER}.${DOMAIN}${RESET}"
echo -e "  ${DIM}  API:       https://api.${CLUSTER}.${DOMAIN}:6443${RESET}"
echo -e "  ${DIM}  Masters:   3x m5.xlarge${RESET}"
echo -e "  ${DIM}  Workers:   2x m5.xlarge + c5.2xlarge pool + GPU pool${RESET}"
echo -e "  ${DIM}  Database:  Aurora PostgreSQL 16.4 + pgvector${RESET}"
echo -e "  ${DIM}  Password:  ${DEFAULT_PASSWORD} (all services)${RESET}"
echo ""

if ! confirm "Proceed with deployment?"; then
  echo -e "${YELLOW}Deployment cancelled.${RESET}"
  exit 0
fi

# =============================================================================
section "PHASE 1.0 — TERRAFORM STATE BACKEND"
# =============================================================================

# Bootstrap S3 + DynamoDB if not exists
TFSTATE_BUCKET="ai-demo-stack-tfstate"
if ! aws s3api head-bucket --bucket "$TFSTATE_BUCKET" --profile "$AWS_PROFILE" 2>/dev/null; then
  log_info "Creating Terraform state backend..."
  bash "${ROOT_DIR}/scripts/bootstrap-state.sh" 2>&1 | tee -a "${LOG_FILE}"
  log_ok "State backend ready"
else
  log_ok "State backend exists: ${TFSTATE_BUCKET}"
fi

# =============================================================================
section "PHASE 1.1 — TERRAFORM INIT"
# =============================================================================

cd "$ENV_DIR" || abort "Cannot navigate to ${ENV_DIR}"

INIT_LOG="${LOG_DIR}/init_${TIMESTAMP}.log"
log_info "Running: terraform init -reconfigure"

terraform init -reconfigure 2>&1 | tee "$INIT_LOG"
TF_INIT_RC=${PIPESTATUS[0]}

if [[ $TF_INIT_RC -eq 0 ]]; then
  log_ok "terraform init succeeded"
else
  log_fail "terraform init failed — see: ${INIT_LOG}"
  abort "Cannot proceed without successful terraform init."
fi

# =============================================================================
section "PHASE 1.2 — TERRAFORM PLAN"
# =============================================================================

PLAN_LOG="${LOG_DIR}/plan_${TIMESTAMP}.log"
log_info "Running: terraform plan -out=tfplan"

terraform plan -out=tfplan 2>&1 | tee "$PLAN_LOG"
TF_PLAN_RC=${PIPESTATUS[0]}

if [[ $TF_PLAN_RC -eq 0 ]]; then
  RESOURCE_COUNT=$(grep -c "will be created\|will be updated\|will be destroyed" "$PLAN_LOG" || echo "0")
  log_ok "terraform plan succeeded — ${RESOURCE_COUNT} resource changes"
else
  log_fail "terraform plan failed — see: ${PLAN_LOG}"
  abort "Fix plan errors before proceeding."
fi

# =============================================================================
section "PHASE 1.3 — TERRAFORM APPLY"
# =============================================================================

APPLY_LOG="${LOG_DIR}/apply_${TIMESTAMP}.log"
MAX_ATTEMPTS=3
ATTEMPT=0

while [[ $ATTEMPT -lt $MAX_ATTEMPTS ]]; do
  ATTEMPT=$((ATTEMPT + 1))
  log_info "Terraform apply — attempt ${ATTEMPT}/${MAX_ATTEMPTS}"

  terraform apply tfplan 2>&1 | tee "$APPLY_LOG"
  TF_APPLY_RC=${PIPESTATUS[0]}

  if grep -qi "│ Error:" "$APPLY_LOG" 2>/dev/null; then
    TF_APPLY_RC=1
  fi

  if [[ $TF_APPLY_RC -eq 0 ]]; then
    log_ok "terraform apply succeeded"
    break
  fi

  # Only match actual AWS/SSO auth errors, not words like "credentials" in resource names
  if grep -qi "ExpiredToken\|session expired\|SSO session\|InvalidIdentityToken\|not authorized to perform\|security token.*expired" "$APPLY_LOG" 2>/dev/null; then
    log_warn "Auth error detected — re-authenticating..."
    aws_sso_login
    redhat_sso_login
    terraform plan -out=tfplan 2>&1 | tee "$PLAN_LOG"
  else
    log_fail "terraform apply failed (non-auth error) — see: ${APPLY_LOG}"
    abort "Review errors in ${APPLY_LOG}"
  fi
done

[[ $TF_APPLY_RC -ne 0 ]] && abort "terraform apply failed after ${MAX_ATTEMPTS} attempts"

# =============================================================================
section "PHASE 2 — OCP CLUSTER READINESS"
# =============================================================================

KUBECONFIG_PATH="${ENV_DIR}/ocp-install-dir/${CLUSTER}/auth/kubeconfig"
if [[ -f "$KUBECONFIG_PATH" ]]; then
  export KUBECONFIG="$KUBECONFIG_PATH"
  wait_for "OCP cluster version available" \
    "oc get clusterversion version -o jsonpath='{.status.conditions[?(@.type==\"Available\")].status}' | grep -q True" \
    2100 60
  log_ok "OCP cluster is ready"

  OCP_VER=$(oc get clusterversion -o jsonpath='{.items[0].status.desired.version}' 2>/dev/null || echo "unknown")
  CONSOLE=$(oc get route console -n openshift-console -o jsonpath='{.spec.host}' 2>/dev/null || echo "unknown")
  log_info "OCP Version: ${OCP_VER}"
  log_info "Console:     https://${CONSOLE}"
else
  log_warn "No kubeconfig found — OCP install may still be in progress"
fi

# =============================================================================
section "PHASE 3 — GITOPS BOOTSTRAP (ArgoCD + 28 apps)"
# =============================================================================

if [[ -f "$KUBECONFIG_PATH" ]]; then
  export KUBECONFIG="$KUBECONFIG_PATH"
  if [[ -f "${ROOT_DIR}/gitops/bootstrap-argocd.sh" ]]; then
    log_info "Running ArgoCD bootstrap..."
    bash "${ROOT_DIR}/gitops/bootstrap-argocd.sh" 2>&1 | tee -a "${LOG_FILE}"
    [[ ${PIPESTATUS[0]} -eq 0 ]] && log_ok "ArgoCD bootstrap completed" || log_warn "ArgoCD bootstrap had issues"
  fi
fi

# =============================================================================
section "PHASE 3.2 — WAIT FOR ARGOCD SYNC"
# =============================================================================

if [[ -f "$KUBECONFIG_PATH" ]] && oc whoami &>/dev/null 2>&1; then
  export KUBECONFIG="$KUBECONFIG_PATH"
  wait_for "ArgoCD applications synced" \
    "oc get applications.argoproj.io -n openshift-gitops -o jsonpath='{range .items[*]}{.status.sync.status}{\" \"}{end}' 2>/dev/null | grep -v OutOfSync | grep -q Synced" \
    1200 30 || log_warn "Some ArgoCD apps may not be fully synced yet"
fi

# =============================================================================
section "PHASE 4 — QUALITY CHECK"
# =============================================================================

if [[ -f "${ROOT_DIR}/scripts/quality-check.sh" ]]; then
  bash "${ROOT_DIR}/scripts/quality-check.sh" 2>&1 | tee -a "${LOG_FILE}"
fi

# =============================================================================
section "DEPLOYMENT COMPLETE"
# =============================================================================

echo ""
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${GREEN}${BOLD}║                    DEPLOYMENT COMPLETE                               ║${RESET}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════════════════════╝${RESET}"
echo ""
echo -e "${CYAN}Application URLs:${RESET}"
echo -e "  OCP Console:      https://console-openshift-console.apps.${CLUSTER}.${DOMAIN}"
echo -e "  ArgoCD:           https://openshift-gitops-server-openshift-gitops.apps.${CLUSTER}.${DOMAIN}"
echo -e "  RHOAI Dashboard:  https://rhods-dashboard-redhat-ods-applications.apps.${CLUSTER}.${DOMAIN}"
echo -e "  Open WebUI:       https://open-webui-rhoai-demo.apps.${CLUSTER}.${DOMAIN}"
echo -e "  n8n:              https://n8n-rhoai-demo.apps.${CLUSTER}.${DOMAIN}"
echo -e "  Grafana:          https://grafana-rhoai-monitoring.apps.${CLUSTER}.${DOMAIN}"
echo -e "  Vault:            https://vault-vault.apps.${CLUSTER}.${DOMAIN}"
echo -e "  Portkey:          https://portkey-rhoai-demo.apps.${CLUSTER}.${DOMAIN}"
echo -e "  MLflow:           https://mlflow-rhoai-mlflow.apps.${CLUSTER}.${DOMAIN}"
echo -e "  Keycloak:         https://keycloak-rhoai-sso.apps.${CLUSTER}.${DOMAIN}"
echo -e "  Kiali:            https://kiali-istio-system.apps.${CLUSTER}.${DOMAIN}"
echo -e "  MinIO:            https://minio-console-rhoai-minio.apps.${CLUSTER}.${DOMAIN}"
echo ""
echo -e "${CYAN}Credentials (all services):${RESET}"
echo -e "  Username:  admin"
echo -e "  Password:  ${DEFAULT_PASSWORD}"
echo ""

print_summary
