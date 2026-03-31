# =============================================================================
#  ENVIRONMENT: demo — AI Demo Stack on AWS
#
#  Fully automatic provisioning:
#    Phase 1: AWS Platform (VPC, DNS, SGs, S3, Aurora, EFS, ECR, Lambda)
#    Phase 2: OCP 4.20 IPI Cluster (3 masters + workers + GPU pool)
#    Phase 3: IAM/IRSA (OIDC + service account roles)
#
#  Domain: *.apps.ai-demo.iisdemolab.com
#  After terraform apply, deploy.sh runs GitOps bootstrap automatically.
# =============================================================================

locals {
  name   = "${var.project_name}-${var.environment}"
  region = var.aws_region
  tags = {
    Environment = var.environment
    Project     = var.project_name
    ManagedBy   = "terraform"
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# MODULE 1: VPC + Networking
# ─────────────────────────────────────────────────────────────────────────────
module "vpc" {
  source = "../../modules/vpc"

  name         = local.name
  cluster_name = var.cluster_name

  vpc_cidr             = var.vpc_cidr
  availability_zones   = var.availability_zones
  public_subnet_cidrs  = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs

  tags = local.tags
}

# ─────────────────────────────────────────────────────────────────────────────
# MODULE 2: Route53 Hosted Zone (required for OCP IPI)
# ─────────────────────────────────────────────────────────────────────────────
module "route53" {
  source = "../../modules/route53"

  name        = local.name
  base_domain = var.base_domain

  tags = local.tags
}

# ─────────────────────────────────────────────────────────────────────────────
# MODULE 3: Security Groups
# ─────────────────────────────────────────────────────────────────────────────
module "security_groups" {
  source = "../../modules/security-groups"

  name     = local.name
  vpc_id   = module.vpc.vpc_id
  vpc_cidr = module.vpc.vpc_cidr

  tags       = local.tags
  depends_on = [module.vpc]
}

# ─────────────────────────────────────────────────────────────────────────────
# MODULE 4: S3 Data Lake
# ─────────────────────────────────────────────────────────────────────────────
module "s3" {
  source = "../../modules/s3-data-lake"

  bucket_prefix               = local.name
  pipeline_log_retention_days = var.pipeline_log_retention_days

  tags = local.tags
}

# ─────────────────────────────────────────────────────────────────────────────
# MODULE 5: Aurora Serverless v2 PostgreSQL + pgvector
# ─────────────────────────────────────────────────────────────────────────────
module "aurora" {
  source = "../../modules/aurora-serverless"

  cluster_identifier    = "${local.name}-db"
  database_name         = var.db_name
  master_username       = var.db_master_username
  master_password       = var.db_master_password
  engine_version        = var.aurora_engine_version
  min_acu               = var.aurora_min_acu
  max_acu               = var.aurora_max_acu
  subnet_ids            = module.vpc.private_subnet_ids
  security_group_ids    = [module.security_groups.aurora_sg_id]
  ssm_path_prefix       = local.name
  skip_final_snapshot   = var.aurora_skip_snapshot
  deletion_protection   = var.aurora_deletion_protection
  backup_retention_days = var.aurora_backup_retention

  tags       = local.tags
  depends_on = [module.vpc, module.security_groups]
}

# ─────────────────────────────────────────────────────────────────────────────
# MODULE 6: EFS Storage
# ─────────────────────────────────────────────────────────────────────────────
module "efs" {
  source = "../../modules/efs-storage"

  name               = local.name
  vpc_id             = module.vpc.vpc_id
  subnet_ids         = module.vpc.private_subnet_ids
  security_group_ids = [module.security_groups.efs_sg_id]
  ssm_path_prefix    = local.name

  tags       = local.tags
  depends_on = [module.vpc, module.security_groups]
}

# ─────────────────────────────────────────────────────────────────────────────
# MODULE 7: ECR Repositories
# ─────────────────────────────────────────────────────────────────────────────
module "ecr" {
  source = "../../modules/ecr-repos"

  repository_names     = var.ecr_repository_names
  image_tag_mutability = var.ecr_image_tag_mutability
  scan_on_push         = var.ecr_scan_on_push

  tags = local.tags
}

# ─────────────────────────────────────────────────────────────────────────────
# MODULE 8: Lambda Automation (scheduler + budget alerts)
# ─────────────────────────────────────────────────────────────────────────────
module "lambda" {
  source = "../../modules/lambda-automation"

  name                = local.name
  cluster_name        = var.cluster_name
  alert_email         = var.budget_alert_email
  monthly_budget_usd  = var.monthly_budget_usd
  start_schedule_cron = var.demo_start_cron
  stop_schedule_cron  = var.demo_stop_cron

  tags = local.tags
}

# ─────────────────────────────────────────────────────────────────────────────
# MODULE 9: OCP 4.21 IPI Cluster
# Gated on pull_secret — skipped if empty (first run without pull secret).
# deploy.sh always sets pull_secret, so this runs on every deploy.
# ─────────────────────────────────────────────────────────────────────────────
module "ocp" {
  source = "../../modules/ocp-ipi"
  count  = var.pull_secret != "" ? 1 : 0

  cluster_name         = var.cluster_name
  base_domain          = var.base_domain
  ocp_version          = var.ocp_version
  aws_region           = var.aws_region
  aws_profile           = var.aws_profile
  aws_access_key_id     = var.ocp_aws_access_key_id
  aws_secret_access_key = var.ocp_aws_secret_access_key
  master_instance_type  = var.master_instance_type
  master_count         = var.master_count
  worker_instance_type = var.initial_worker_instance_type
  worker_count         = var.initial_worker_count
  vpc_cidr             = var.vpc_cidr
  private_subnet_ids   = module.vpc.private_subnet_ids
  public_subnet_ids    = module.vpc.public_subnet_ids
  pull_secret          = var.pull_secret
  ssh_public_key       = var.ssh_public_key
  admin_password       = var.admin_password
  efs_file_system_id   = module.efs.file_system_id
  install_dir          = "${path.module}/ocp-install-dir"

  tags       = local.tags
  depends_on = [module.vpc, module.security_groups, module.route53, module.efs]
}

# ─────────────────────────────────────────────────────────────────────────────
# MODULE 10: Compute MachineSets (additional worker pools)
# Gated on OCP cluster being installed (kubeconfig must exist)
# ─────────────────────────────────────────────────────────────────────────────
locals {
  ocp_installed    = length(module.ocp) > 0
  infra_id_from_file = try(trimspace(file("${path.module}/ocp-install-dir/${var.cluster_name}/infrastructure-id")), "")
  compute_ready    = local.ocp_installed && local.infra_id_from_file != ""
}

module "compute" {
  source = "../../modules/compute"
  count  = local.compute_ready ? 1 : 0

  cluster_name          = var.cluster_name
  infrastructure_id     = local.infra_id_from_file
  availability_zones    = var.availability_zones
  compute_instance_type = var.compute_instance_type
  compute_min_replicas  = var.compute_min_replicas
  compute_max_replicas  = var.compute_max_replicas
  gpu_instance_type     = var.gpu_instance_type
  gpu_max_replicas      = var.gpu_max_replicas
  kubeconfig_path       = module.ocp[0].kubeconfig_path
  output_dir            = "${path.module}/generated"

  tags       = local.tags
  depends_on = [module.ocp]
}

# ─────────────────────────────────────────────────────────────────────────────
# MODULE 11: IAM / IRSA
# Requires OCP cluster OIDC issuer URL — only created after cluster is running.
# On first deploy: skipped (count=0). After OCP install writes oidc-issuer-url
# file, second terraform apply creates the IRSA roles automatically.
# ─────────────────────────────────────────────────────────────────────────────
locals {
  oidc_url_from_file = trimspace(try(file("${path.module}/ocp-install-dir/${var.cluster_name}/oidc-issuer-url"), ""))
  oidc_url           = local.oidc_url_from_file != "" ? local.oidc_url_from_file : var.oidc_issuer_url
  irsa_enabled       = local.oidc_url != ""
}

module "iam_irsa" {
  source = "../../modules/iam-irsa"
  count  = local.irsa_enabled ? 1 : 0

  cluster_name          = var.cluster_name
  aws_region            = var.aws_region
  oidc_issuer_url       = local.oidc_url
  s3_bucket_arn         = module.s3.bucket_arn
  enable_bedrock_access = var.enable_bedrock_access
  ssm_path_prefix       = local.name

  tags       = local.tags
  depends_on = [module.s3]
}
