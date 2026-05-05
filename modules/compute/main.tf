# =============================================================================
#  MachineSet + MachineAutoscaler definitions for OCP worker pools
#  Applied via oc apply post-cluster-install
# =============================================================================

# ── Generate MachineSet YAMLs ───────────────────────────────────────────────
resource "local_file" "compute_machineset_a" {
  filename = "${var.output_dir}/machineset-compute-${var.availability_zones[0]}.yaml"
  content  = templatefile("${path.module}/templates/machineset.yaml.tpl", {
    cluster_name      = var.cluster_name
    infrastructure_id = var.infrastructure_id
    instance_type     = var.compute_instance_type
    az                = var.availability_zones[0]
    subnet_filter     = "${var.infrastructure_id}-private-${var.availability_zones[0]}"
    role              = "compute"
    replicas          = var.compute_min_replicas
    ami_id            = var.ami_id
    sg_filter         = "${var.infrastructure_id}-worker-sg"
    labels            = "node-role.kubernetes.io/compute: \"\""
  })
}

resource "local_file" "compute_machineset_b" {
  filename = "${var.output_dir}/machineset-compute-${var.availability_zones[1]}.yaml"
  content  = templatefile("${path.module}/templates/machineset.yaml.tpl", {
    cluster_name      = var.cluster_name
    infrastructure_id = var.infrastructure_id
    instance_type     = var.compute_instance_type
    az                = var.availability_zones[1]
    subnet_filter     = "${var.infrastructure_id}-private-${var.availability_zones[1]}"
    role              = "compute"
    replicas          = var.compute_min_replicas
    ami_id            = var.ami_id
    sg_filter         = "${var.infrastructure_id}-worker-sg"
    labels            = "node-role.kubernetes.io/compute: \"\""
  })
}

resource "local_file" "gpu_machineset" {
  filename = "${var.output_dir}/machineset-gpu-${var.availability_zones[0]}.yaml"
  content  = templatefile("${path.module}/templates/machineset.yaml.tpl", {
    cluster_name      = var.cluster_name
    infrastructure_id = var.infrastructure_id
    instance_type     = var.gpu_instance_type
    az                = var.availability_zones[0]
    subnet_filter     = "${var.infrastructure_id}-private-${var.availability_zones[0]}"
    role              = "gpu-demo"
    replicas          = 0
    ami_id            = var.ami_id
    sg_filter         = "${var.infrastructure_id}-worker-sg"
    labels            = "node-role.kubernetes.io/gpu: \"\"\n        nvidia.com/gpu.present: \"true\""
  })
}

# ── Generate MachineAutoscaler YAMLs ────────────────────────────────────────
resource "local_file" "compute_autoscaler" {
  filename = "${var.output_dir}/machineautoscaler-compute.yaml"
  content  = <<-YAML
apiVersion: autoscaling.openshift.io/v1beta1
kind: MachineAutoscaler
metadata:
  name: ${var.infrastructure_id}-compute-${var.availability_zones[0]}
  namespace: openshift-machine-api
spec:
  minReplicas: ${var.compute_min_replicas}
  maxReplicas: ${var.compute_max_replicas}
  scaleTargetRef:
    apiVersion: machine.openshift.io/v1beta1
    kind: MachineSet
    name: ${var.infrastructure_id}-compute-${var.availability_zones[0]}
---
apiVersion: autoscaling.openshift.io/v1beta1
kind: MachineAutoscaler
metadata:
  name: ${var.infrastructure_id}-compute-${var.availability_zones[1]}
  namespace: openshift-machine-api
spec:
  minReplicas: ${var.compute_min_replicas}
  maxReplicas: ${var.compute_max_replicas}
  scaleTargetRef:
    apiVersion: machine.openshift.io/v1beta1
    kind: MachineSet
    name: ${var.infrastructure_id}-compute-${var.availability_zones[1]}
YAML
}

resource "local_file" "gpu_autoscaler" {
  filename = "${var.output_dir}/machineautoscaler-gpu.yaml"
  content  = <<-YAML
apiVersion: autoscaling.openshift.io/v1beta1
kind: MachineAutoscaler
metadata:
  name: ${var.infrastructure_id}-gpu-demo-${var.availability_zones[0]}
  namespace: openshift-machine-api
spec:
  minReplicas: 0
  maxReplicas: ${var.gpu_max_replicas}
  scaleTargetRef:
    apiVersion: machine.openshift.io/v1beta1
    kind: MachineSet
    name: ${var.infrastructure_id}-gpu-demo-${var.availability_zones[0]}
YAML
}

# ── Apply MachineSets to cluster ────────────────────────────────────────────
resource "null_resource" "apply_machinesets" {
  depends_on = [
    local_file.compute_machineset_a,
    local_file.compute_machineset_b,
    local_file.gpu_machineset,
    local_file.compute_autoscaler,
    local_file.gpu_autoscaler,
  ]

  provisioner "local-exec" {
    command = <<-EOT
      export KUBECONFIG="${var.kubeconfig_path}"

      # Auto-detect AMI from existing installer-created worker MachineSet
      DETECTED_AMI=$(oc get machineset -n openshift-machine-api -o jsonpath='{.items[0].spec.template.spec.providerSpec.value.ami.id}' 2>/dev/null || echo "")
      if [[ -z "$DETECTED_AMI" ]]; then
        echo "ERROR: Could not detect RHCOS AMI from existing MachineSets"
        exit 1
      fi
      echo "Detected RHCOS AMI: $DETECTED_AMI"

      # Inject AMI into MachineSet YAMLs if not already set.
      # Uses awk for portability — `sed -i ... i\` differs between BSD (macOS)
      # and GNU sed and silently produced a single-line `id: ami-... placement:`
      # collapse on macOS, breaking YAML parsing.
      echo "Applying MachineSets and Autoscalers..."
      for f in ${var.output_dir}/machineset-*.yaml; do
        if ! grep -q "ami:" "$f"; then
          awk -v ami="$DETECTED_AMI" '
            /^[[:space:]]*placement:/ && !done {
              n = match($0, /[^ ]/) - 1
              pad = sprintf("%*s", n, "")
              print pad "ami:"
              print pad "  id: " ami
              done = 1
            }
            { print }
          ' "$f" > "$f.new" && mv "$f.new" "$f"
          echo "  Injected AMI $DETECTED_AMI into $f"
        fi
        oc apply -f "$f" && echo "Applied $f"
      done
      for f in ${var.output_dir}/machineautoscaler-*.yaml; do
        oc apply -f "$f" && echo "Applied $f"
      done
      echo "MachineSets and Autoscalers applied."
    EOT
  }

  triggers = {
    compute_type = var.compute_instance_type
    gpu_type     = var.gpu_instance_type
  }
}
