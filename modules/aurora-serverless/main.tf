# =============================================================================
#  Aurora Serverless v2 PostgreSQL 16.4 + pgvector
#  Cluster: rhoai-demo-db, DB: rhoai_demo, 0.5-4 ACU
# =============================================================================

resource "aws_db_subnet_group" "aurora" {
  name       = "${var.cluster_identifier}-subnet"
  subnet_ids = var.subnet_ids

  tags = merge(var.tags, {
    Name = "${var.cluster_identifier}-subnet-group"
  })
}

resource "aws_rds_cluster_parameter_group" "aurora" {
  name   = "${var.cluster_identifier}-params"
  family = "aurora-postgresql16"

  parameter {
    name         = "shared_preload_libraries"
    value        = "pg_stat_statements,pgvector"
    apply_method = "pending-reboot"
  }

  parameter {
    name  = "log_min_duration_statement"
    value = "1000"
  }

  tags = merge(var.tags, {
    Name = "${var.cluster_identifier}-params"
  })
}

resource "aws_rds_cluster" "aurora" {
  cluster_identifier              = var.cluster_identifier
  engine                          = "aurora-postgresql"
  engine_mode                     = "provisioned"
  engine_version                  = var.engine_version
  database_name                   = var.database_name
  master_username                 = var.master_username
  master_password                 = var.master_password
  db_subnet_group_name            = aws_db_subnet_group.aurora.name
  db_cluster_parameter_group_name = aws_rds_cluster_parameter_group.aurora.name
  vpc_security_group_ids          = var.security_group_ids
  storage_encrypted               = true
  deletion_protection             = var.deletion_protection
  skip_final_snapshot             = var.skip_final_snapshot
  final_snapshot_identifier       = var.skip_final_snapshot ? null : "${var.cluster_identifier}-final"
  backup_retention_period         = var.backup_retention_days
  enable_http_endpoint            = true
  port                            = 5432

  serverlessv2_scaling_configuration {
    min_capacity = var.min_acu
    max_capacity = var.max_acu
  }

  tags = merge(var.tags, {
    Name = var.cluster_identifier
  })
}

resource "aws_rds_cluster_instance" "aurora" {
  identifier         = "${var.cluster_identifier}-instance-1"
  cluster_identifier = aws_rds_cluster.aurora.id
  instance_class     = "db.serverless"
  engine             = aws_rds_cluster.aurora.engine
  engine_version     = aws_rds_cluster.aurora.engine_version

  tags = merge(var.tags, {
    Name = "${var.cluster_identifier}-instance-1"
  })
}

# ── Store credentials in SSM Parameter Store ────────────────────────────────
resource "aws_ssm_parameter" "db_endpoint" {
  name  = "/${var.ssm_path_prefix}/aurora/endpoint"
  type  = "String"
  value = aws_rds_cluster.aurora.endpoint

  tags = var.tags
}

resource "aws_ssm_parameter" "db_password" {
  name  = "/${var.ssm_path_prefix}/aurora/master-password"
  type  = "SecureString"
  value = var.master_password

  tags = var.tags
}

resource "aws_ssm_parameter" "db_name" {
  name  = "/${var.ssm_path_prefix}/aurora/database-name"
  type  = "String"
  value = var.database_name

  tags = var.tags
}
