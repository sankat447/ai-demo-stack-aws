# =============================================================================
#  EFS — Encrypted, GeneralPurpose, with access point for RHOAI notebooks
# =============================================================================

resource "aws_efs_file_system" "main" {
  encrypted        = true
  performance_mode = "generalPurpose"
  throughput_mode  = "bursting"

  lifecycle_policy {
    transition_to_ia = "AFTER_30_DAYS"
  }

  tags = merge(var.tags, {
    Name = "${var.name}-efs"
  })
}

resource "aws_efs_mount_target" "main" {
  count = length(var.subnet_ids)

  file_system_id  = aws_efs_file_system.main.id
  subnet_id       = var.subnet_ids[count.index]
  security_groups = var.security_group_ids
}

resource "aws_efs_access_point" "rhoai_notebooks" {
  file_system_id = aws_efs_file_system.main.id

  posix_user {
    uid = 1000
    gid = 1000
  }

  root_directory {
    path = "/rhoai-notebooks"
    creation_info {
      owner_uid   = 1000
      owner_gid   = 1000
      permissions = "755"
    }
  }

  tags = merge(var.tags, {
    Name = "${var.name}-rhoai-notebooks-ap"
  })
}

# ── Store EFS ID in SSM ─────────────────────────────────────────────────────
resource "aws_ssm_parameter" "efs_id" {
  name      = "/${var.ssm_path_prefix}/efs/file-system-id"
  type      = "String"
  value     = aws_efs_file_system.main.id
  overwrite = true

  tags = var.tags
}
