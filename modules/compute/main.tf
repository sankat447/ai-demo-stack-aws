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
    subnet_filter     = "${var.cluster_name}-private-${var.availability_zones[0]}"
    role              = "compute"
    replicas          = var.compute_min_replicas
    ami_id            = var.ami_id
    sg_filter         = "${var.cluster_name}-worker-sg"
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
    subnet_filter     = "${var.cluster_name}-private-${var.availability_zones[1]}"
    role              = "compute"
    replicas          = var.compute_min_replicas
    ami_id            = var.ami_id
    sg_filter         = "${var.cluster_name}-worker-sg"
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
    subnet_filter     = "${var.cluster_name}-private-${var.availability_zones[0]}"
    role              = "gpu-demo"
    replicas          = 0
    ami_id            = var.ami_id
    sg_filter         = "${var.cluster_name}-worker-sg"
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
      echo "Applying MachineSets and Autoscalers..."
      for f in ${var.output_dir}/machineset-*.yaml; do
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
