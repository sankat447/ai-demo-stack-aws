# =============================================================================
#  Outputs — Resource IDs, endpoints, URLs, and connection details
# =============================================================================

# ── VPC ──────────────────────────────────────────────────────────────────────
output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}

output "private_subnet_ids" {
  description = "Private subnet IDs"
  value       = module.vpc.private_subnet_ids
}

output "public_subnet_ids" {
  description = "Public subnet IDs"
  value       = module.vpc.public_subnet_ids
}

output "nat_gateway_ip" {
  description = "NAT Gateway public IP"
  value       = module.vpc.nat_gateway_ip
}

# ── DNS ──────────────────────────────────────────────────────────────────────
output "route53_zone_id" {
  description = "Route53 hosted zone ID"
  value       = module.route53.zone_id
}

output "route53_name_servers" {
  description = "Route53 name servers (delegate from your registrar)"
  value       = module.route53.name_servers
}

# ── S3 ───────────────────────────────────────────────────────────────────────
output "s3_bucket_name" {
  description = "S3 data lake bucket name"
  value       = module.s3.bucket_name
}

output "s3_bucket_arn" {
  description = "S3 data lake bucket ARN"
  value       = module.s3.bucket_arn
}

# ── Aurora ───────────────────────────────────────────────────────────────────
output "aurora_endpoint" {
  description = "Aurora cluster endpoint"
  value       = module.aurora.cluster_endpoint
}

output "aurora_database_name" {
  description = "Aurora database name"
  value       = module.aurora.database_name
}

output "aurora_port" {
  description = "Aurora port"
  value       = module.aurora.port
}

# ── EFS ──────────────────────────────────────────────────────────────────────
output "efs_file_system_id" {
  description = "EFS file system ID"
  value       = module.efs.file_system_id
}

output "efs_access_point_id" {
  description = "EFS access point ID"
  value       = module.efs.access_point_id
}

# ── ECR ──────────────────────────────────────────────────────────────────────
output "ecr_repository_urls" {
  description = "ECR repository URLs"
  value       = module.ecr.repository_urls
}

# ── Lambda ───────────────────────────────────────────────────────────────────
output "scheduler_lambda_arn" {
  description = "Lambda scheduler ARN"
  value       = module.lambda.scheduler_lambda_arn
}

output "budget_name" {
  description = "AWS Budget name"
  value       = module.lambda.budget_name
}

# ── Security Groups ─────────────────────────────────────────────────────────
output "ocp_nodes_sg_id" {
  description = "OCP nodes security group ID"
  value       = module.security_groups.ocp_nodes_sg_id
}

output "aurora_sg_id" {
  description = "Aurora security group ID"
  value       = module.security_groups.aurora_sg_id
}

output "efs_sg_id" {
  description = "EFS security group ID"
  value       = module.security_groups.efs_sg_id
}

# ── OCP Cluster (created when pull_secret is set) ────────────────────────────
output "ocp_api_url" {
  description = "OCP API URL"
  value       = length(module.ocp) > 0 ? module.ocp[0].api_url : "(pending OCP install)"
}

output "ocp_console_url" {
  description = "OCP Console URL"
  value       = length(module.ocp) > 0 ? module.ocp[0].console_url : "(pending OCP install)"
}

output "ocp_apps_domain" {
  description = "OCP wildcard apps domain"
  value       = length(module.ocp) > 0 ? module.ocp[0].apps_domain : "(pending OCP install)"
}

output "ocp_kubeconfig_path" {
  description = "Path to kubeconfig"
  value       = length(module.ocp) > 0 ? module.ocp[0].kubeconfig_path : "(pending OCP install)"
}

# ── IAM / IRSA (created after OCP cluster is running) ────────────────────────
output "irsa_s3_role_arn" {
  description = "IRSA role for S3 access"
  value       = length(module.iam_irsa) > 0 ? module.iam_irsa[0].s3_role_arn : "(pending OCP install)"
}

output "irsa_bedrock_role_arn" {
  description = "IRSA role for Bedrock access"
  value       = length(module.iam_irsa) > 0 ? module.iam_irsa[0].bedrock_role_arn : "(pending OCP install)"
}

output "irsa_ecr_role_arn" {
  description = "IRSA role for ECR access"
  value       = length(module.iam_irsa) > 0 ? module.iam_irsa[0].ecr_role_arn : "(pending OCP install)"
}

output "irsa_ssm_role_arn" {
  description = "IRSA role for SSM access"
  value       = length(module.iam_irsa) > 0 ? module.iam_irsa[0].ssm_role_arn : "(pending OCP install)"
}

# ── Application URLs (after GitOps deployment) ──────────────────────────────
output "app_urls" {
  description = "Expected application URLs after GitOps deployment"
  value = {
    ocp_console    = "https://console-openshift-console.apps.${var.cluster_name}.${var.base_domain}"
    argocd         = "https://openshift-gitops-server-openshift-gitops.apps.${var.cluster_name}.${var.base_domain}"
    rhoai_dashboard = "https://rhods-dashboard-redhat-ods-applications.apps.${var.cluster_name}.${var.base_domain}"
    open_webui     = "https://open-webui-rhoai-demo.apps.${var.cluster_name}.${var.base_domain}"
    n8n            = "https://n8n-rhoai-demo.apps.${var.cluster_name}.${var.base_domain}"
    grafana        = "https://grafana-rhoai-monitoring.apps.${var.cluster_name}.${var.base_domain}"
    vault          = "https://vault-vault.apps.${var.cluster_name}.${var.base_domain}"
    portkey        = "https://portkey-rhoai-demo.apps.${var.cluster_name}.${var.base_domain}"
    mlflow         = "https://mlflow-rhoai-mlflow.apps.${var.cluster_name}.${var.base_domain}"
    minio          = "https://minio-console-rhoai-minio.apps.${var.cluster_name}.${var.base_domain}"
    keycloak       = "https://keycloak-rhoai-sso.apps.${var.cluster_name}.${var.base_domain}"
    kiali          = "https://kiali-istio-system.apps.${var.cluster_name}.${var.base_domain}"
    cloudbeaver    = "https://cloudbeaver-rhoai-tools.apps.${var.cluster_name}.${var.base_domain}"
    langchain      = "https://langchain-server-langchain.apps.${var.cluster_name}.${var.base_domain}"
  }
}
