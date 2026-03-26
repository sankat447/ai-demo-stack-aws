output "machineset_files" {
  description = "List of generated MachineSet YAML files"
  value = [
    local_file.compute_machineset_a.filename,
    local_file.compute_machineset_b.filename,
    local_file.gpu_machineset.filename,
  ]
}

output "autoscaler_files" {
  description = "List of generated MachineAutoscaler YAML files"
  value = [
    local_file.compute_autoscaler.filename,
    local_file.gpu_autoscaler.filename,
  ]
}
