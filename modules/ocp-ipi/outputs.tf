output "kubeconfig_path" {
  description = "Path to kubeconfig file"
  value       = "${local.install_dir}/auth/kubeconfig"
}

output "kubeadmin_password" {
  description = "kubeadmin password (read from file after install)"
  value       = try(file("${local.install_dir}/auth/kubeadmin-password"), "(pending install)")
  sensitive   = true
}

output "install_dir" {
  description = "OCP install directory"
  value       = local.install_dir
}

output "api_url" {
  description = "OCP API URL"
  value       = local.api_url
}

output "console_url" {
  description = "OCP console URL"
  value       = local.console_url
}

output "apps_domain" {
  description = "Wildcard apps domain"
  value       = "*.${local.apps_domain}"
}

output "oidc_issuer_url_file" {
  description = "Path to file containing OIDC issuer URL (read after apply)"
  value       = "${local.install_dir}/oidc-issuer-url"
}

output "infrastructure_id_file" {
  description = "Path to file containing infrastructure ID (read after apply)"
  value       = "${local.install_dir}/infrastructure-id"
}
