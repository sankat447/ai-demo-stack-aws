# =============================================================================
#  OCP 4.20 IPI Install on AWS — Automatic Configuration
#  Generates install-config.yaml, runs openshift-install, creates admin user
#  Fully automatic — no manual steps required after terraform apply
# =============================================================================

locals {
  install_dir = "${var.install_dir}/${var.cluster_name}"
  api_url     = "https://api.${var.cluster_name}.${var.base_domain}:6443"
  console_url = "https://console-openshift-console.apps.${var.cluster_name}.${var.base_domain}"
  apps_domain = "apps.${var.cluster_name}.${var.base_domain}"
}

# ── Generate install-config.yaml ────────────────────────────────────────────
resource "local_file" "install_config" {
  filename        = "${local.install_dir}/install-config.yaml"
  file_permission = "0600"
  content = templatefile("${path.module}/../../templates/install-config.yaml.tpl", {
    cluster_name = var.cluster_name
    base_domain  = var.base_domain
    aws_region   = var.aws_region
    master_type  = var.master_instance_type
    master_count = var.master_count
    worker_type  = var.worker_instance_type
    worker_count = var.worker_count
    vpc_cidr     = var.vpc_cidr
    machine_cidr = var.vpc_cidr
    subnet_ids   = []
    pull_secret  = var.pull_secret
    ssh_key      = var.ssh_public_key
    fips         = var.fips_enabled
    network_type = var.network_type
  })
}

# ── Run openshift-install create cluster ────────────────────────────────────
resource "null_resource" "ocp_install" {
  depends_on = [local_file.install_config]

  provisioner "local-exec" {
    command = <<-EOT
      set -euo pipefail
      INSTALL_DIR="${local.install_dir}"

      # ── Resolve AWS SSO credentials for openshift-install ────────────────
      # openshift-install requires env vars (not SSO profiles, not credential files).
      # Extract from the AWS CLI cache where SSO stores resolved role credentials.
      echo "Resolving AWS SSO credentials for openshift-install..."

      CALLER=$(aws sts get-caller-identity --profile "${var.aws_profile}" --output json 2>/dev/null)
      echo "Authenticated as: $(echo "$CALLER" | jq -r '.Arn')"

      # Extract credentials from AWS CLI cache into env vars
      eval "$(python3 -c "
import json, glob, os
for cache_dir in [os.path.expanduser('~/.aws/cli/cache'), os.path.expanduser('~/.aws/sso/cache')]:
    if not os.path.isdir(cache_dir): continue
    for f in sorted(glob.glob(os.path.join(cache_dir, '*.json')), key=os.path.getmtime, reverse=True):
        try:
            c = json.load(open(f)).get('Credentials', {})
            if 'AccessKeyId' in c:
                print(f'export AWS_ACCESS_KEY_ID={c[\"AccessKeyId\"]}')
                print(f'export AWS_SECRET_ACCESS_KEY={c[\"SecretAccessKey\"]}')
                if 'SessionToken' in c: print(f'export AWS_SESSION_TOKEN={c[\"SessionToken\"]}')
                exit(0)
        except: pass
exit(1)
" 2>/dev/null)" || { echo "FATAL: Cannot extract AWS credentials from cache"; exit 1; }

      # Clear profile/config to force env var usage only
      unset AWS_PROFILE AWS_SHARED_CREDENTIALS_FILE AWS_CONFIG_FILE 2>/dev/null || true
      export AWS_DEFAULT_REGION="${var.aws_region}"
      echo "Credentials exported as env vars (Key: $${AWS_ACCESS_KEY_ID:0:8}...)"

      # ── Skip if cluster already exists ───────────────────────────────────
      if [[ -f "$INSTALL_DIR/auth/kubeconfig" ]]; then
        echo "Cluster already installed (kubeconfig exists). Skipping installation."
        export KUBECONFIG="$INSTALL_DIR/auth/kubeconfig"
        if oc get clusterversion &>/dev/null; then
          echo "Cluster is reachable. Nothing to do."
          exit 0
        else
          echo "WARNING: kubeconfig exists but cluster unreachable. Proceeding with install..."
        fi
      fi

      echo "================================================================"
      echo "  OCP ${var.ocp_version} IPI Installation — ${var.cluster_name}.${var.base_domain}"
      echo "  Masters: ${var.master_count}x ${var.master_instance_type}"
      echo "  Workers: ${var.worker_count}x ${var.worker_instance_type}"
      echo "  Region:  ${var.aws_region}"
      echo "  This will take 30-45 minutes..."
      echo "================================================================"

      # Backup install-config (openshift-install consumes it)
      cp "$INSTALL_DIR/install-config.yaml" "$INSTALL_DIR/install-config.yaml.bak"

      # Validate install-config has all required fields (prevents interactive prompts)
      for FIELD in baseDomain pullSecret platform sshKey; do
        if ! grep -q "^${FIELD}:" "$INSTALL_DIR/install-config.yaml" && \
           ! grep -q "^${FIELD}: " "$INSTALL_DIR/install-config.yaml"; then
          echo "FATAL: install-config.yaml missing required field: $FIELD"
          echo "This would cause the installer to prompt interactively and hang."
          exit 1
        fi
      done
      echo "install-config.yaml validated — all required fields present."

      # Run the installer — DO NOT pipe through tee!
      # Piping hides interactive prompts and causes silent hangs.
      # The installer writes its own log to .openshift_install.log in the dir.
      if openshift-install create cluster \
        --dir="$INSTALL_DIR" \
        --log-level=info; then
        echo "OCP installation completed successfully."
      else
        echo "ERROR: OCP installation failed. Check $INSTALL_DIR/.openshift_install.log"
        echo "To retry: openshift-install create cluster --dir=$INSTALL_DIR --log-level=debug"
        exit 1
      fi

      # Verify cluster is accessible
      export KUBECONFIG="$INSTALL_DIR/auth/kubeconfig"
      echo "Verifying cluster accessibility..."
      for i in $(seq 1 10); do
        if oc get clusterversion &>/dev/null; then
          OCP_VER=$(oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null)
          echo "Cluster verified: OCP $OCP_VER is running."
          break
        fi
        echo "  Waiting for API... (attempt $i/10)"
        sleep 30
      done
    EOT
    environment = {
      HOME = pathexpand("~")
    }
  }

  # Only re-trigger if install-config content changes
  triggers = {
    install_config_hash = local_file.install_config.content_sha256
  }
}

# ── Wait for cluster operators to stabilize ─────────────────────────────────
resource "null_resource" "wait_cluster_ready" {
  depends_on = [null_resource.ocp_install]

  provisioner "local-exec" {
    command = <<-EOT
      set -euo pipefail
      export KUBECONFIG="${local.install_dir}/auth/kubeconfig"

      echo "Waiting for all cluster operators to become available..."

      # Wait for clusterversion
      oc wait clusterversion/version --for=condition=Available --timeout=1200s || {
        echo "WARNING: ClusterVersion not yet Available after 20min"
        oc get clusterversion
      }

      # Check for degraded operators
      DEGRADED=$(oc get clusteroperators -o json | \
        python3 -c "
import json, sys
data = json.load(sys.stdin)
degraded = []
for op in data.get('items', []):
    for c in op.get('status', {}).get('conditions', []):
        if c.get('type') == 'Degraded' and c.get('status') == 'True':
            degraded.append(op['metadata']['name'])
print(','.join(degraded))
" 2>/dev/null || echo "")

      if [[ -n "$DEGRADED" ]]; then
        echo "WARNING: Degraded operators: $DEGRADED"
      else
        echo "All cluster operators healthy."
      fi

      echo "Cluster ready: ${local.console_url}"
    EOT
    environment = {
      KUBECONFIG = "${local.install_dir}/auth/kubeconfig"
    }
  }
}

# ── Create admin + developer users with HTPasswd ───────────────────────────
resource "null_resource" "cluster_admin" {
  depends_on = [null_resource.wait_cluster_ready]

  provisioner "local-exec" {
    command = <<-EOT
      set -euo pipefail
      export KUBECONFIG="${local.install_dir}/auth/kubeconfig"

      echo "Creating HTPasswd identity provider..."

      # Generate htpasswd file
      HTPASSWD_FILE=$(mktemp)
      htpasswd -c -B -b "$HTPASSWD_FILE" admin '${var.admin_password}' 2>/dev/null
      htpasswd -B -b "$HTPASSWD_FILE" developer '${var.admin_password}' 2>/dev/null

      # Create or update the secret
      oc create secret generic htpass-secret \
        --from-file=htpasswd="$HTPASSWD_FILE" \
        -n openshift-config --dry-run=client -o yaml | oc apply -f -

      rm -f "$HTPASSWD_FILE"

      # Configure OAuth with HTPasswd provider
      oc apply -f - <<'OAUTH'
apiVersion: config.openshift.io/v1
kind: OAuth
metadata:
  name: cluster
spec:
  identityProviders:
  - name: htpasswd
    type: HTPasswd
    mappingMethod: claim
    htpasswd:
      fileData:
        name: htpass-secret
OAUTH

      # Grant cluster-admin
      oc adm policy add-cluster-role-to-user cluster-admin admin
      oc adm policy add-role-to-user admin developer -n ai-demo 2>/dev/null || true

      echo "Users created:"
      echo "  admin     / ${var.admin_password}  (cluster-admin)"
      echo "  developer / ${var.admin_password}  (project admin)"
    EOT
    environment = {
      KUBECONFIG = "${local.install_dir}/auth/kubeconfig"
    }
  }
}

# ── Create StorageClasses (efs-sc) ──────────────────────────────────────────
resource "null_resource" "storage_classes" {
  depends_on = [null_resource.wait_cluster_ready]

  provisioner "local-exec" {
    command = <<-EOT
      set -euo pipefail
      export KUBECONFIG="${local.install_dir}/auth/kubeconfig"

      echo "Configuring StorageClasses..."

      # gp3-csi is created by OCP IPI automatically — ensure it's default
      oc annotate storageclass gp3-csi \
        storageclass.kubernetes.io/is-default-class=true --overwrite 2>/dev/null || true

      # efs-sc will be created by the EFS CSI operator once deployed via GitOps
      # Pre-create the StorageClass definition so PVCs don't fail
      oc apply -f - <<'SC'
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: efs-sc
provisioner: efs.csi.aws.com
parameters:
  provisioningMode: efs-ap
  fileSystemId: "${var.efs_file_system_id}"
  directoryPerms: "700"
  uid: "1000"
  gid: "1000"
SC

      echo "StorageClasses configured: gp3-csi (default), efs-sc (RWX)"
    EOT
    environment = {
      KUBECONFIG = "${local.install_dir}/auth/kubeconfig"
    }
  }
}

# ── Extract OIDC issuer URL for IRSA ───────────────────────────────────────
resource "null_resource" "extract_oidc" {
  depends_on = [null_resource.wait_cluster_ready]

  provisioner "local-exec" {
    command = <<-EOT
      set -euo pipefail
      export KUBECONFIG="${local.install_dir}/auth/kubeconfig"

      # Extract the OIDC issuer URL from the cluster
      OIDC_URL=$(oc get authentication cluster -o jsonpath='{.spec.serviceAccountIssuer}' 2>/dev/null || echo "")
      if [[ -n "$OIDC_URL" ]]; then
        echo "$OIDC_URL" > "${local.install_dir}/oidc-issuer-url"
        echo "OIDC Issuer URL: $OIDC_URL"
      else
        echo "WARNING: Could not extract OIDC issuer URL"
      fi

      # Extract infrastructure ID
      INFRA_ID=$(oc get infrastructure cluster -o jsonpath='{.status.infrastructureName}' 2>/dev/null || echo "")
      if [[ -n "$INFRA_ID" ]]; then
        echo "$INFRA_ID" > "${local.install_dir}/infrastructure-id"
        echo "Infrastructure ID: $INFRA_ID"
      fi
    EOT
    environment = {
      KUBECONFIG = "${local.install_dir}/auth/kubeconfig"
    }
  }
}

# ── Outputs read from install directory (only if files exist) ──────────────
