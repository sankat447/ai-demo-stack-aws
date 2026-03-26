# =============================================================================
#  S3 Data Lake — versioned, encrypted, with folder structure and lifecycle
# =============================================================================

resource "aws_s3_bucket" "data_lake" {
  bucket        = "${var.bucket_prefix}-data-lake"
  force_destroy = var.force_destroy

  tags = merge(var.tags, {
    Name = "${var.bucket_prefix}-data-lake"
  })
}

resource "aws_s3_bucket_versioning" "data_lake" {
  bucket = aws_s3_bucket.data_lake.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "data_lake" {
  bucket = aws_s3_bucket.data_lake.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "data_lake" {
  bucket = aws_s3_bucket.data_lake.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "data_lake" {
  bucket = aws_s3_bucket.data_lake.id

  rule {
    id     = "expire-pipeline-logs"
    status = "Enabled"
    filter {
      prefix = "pipelines/logs/"
    }
    expiration {
      days = var.pipeline_log_retention_days
    }
  }

  rule {
    id     = "archive-old-models"
    status = "Enabled"
    filter {
      prefix = "models/"
    }
    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }
  }

  rule {
    id     = "archive-processed-datasets"
    status = "Enabled"
    filter {
      prefix = "datasets/processed/"
    }
    transition {
      days          = 60
      storage_class = "STANDARD_IA"
    }
  }
}

# ── Create folder structure via empty objects ───────────────────────────────
locals {
  folders = [
    "models/",
    "datasets/raw/",
    "datasets/processed/",
    "pipelines/logs/",
    "notebooks/",
    "archived/",
  ]
}

resource "aws_s3_object" "folders" {
  for_each = toset(local.folders)

  bucket  = aws_s3_bucket.data_lake.id
  key     = each.value
  content = ""
}
