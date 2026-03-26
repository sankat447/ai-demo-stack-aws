# =============================================================================
#  IAM OIDC Provider + IRSA Roles for OCP Service Accounts
#  Roles: rhoai-s3-access, rhoai-bedrock-access, rhoai-ecr-access, rhoai-ssm-access
# =============================================================================

# ── OIDC Provider for OCP cluster ──────────────────────────────────────────
resource "aws_iam_openid_connect_provider" "ocp" {
  url             = var.oidc_issuer_url
  client_id_list  = ["openshift", "sts.amazonaws.com"]
  thumbprint_list = [var.oidc_thumbprint]

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-oidc"
  })
}

locals {
  oidc_provider_arn = aws_iam_openid_connect_provider.ocp.arn
  oidc_issuer_host  = replace(var.oidc_issuer_url, "https://", "")
}

# ── S3 Access Role ──────────────────────────────────────────────────────────
resource "aws_iam_role" "s3_access" {
  name = "${var.cluster_name}-s3-access"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = local.oidc_provider_arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_issuer_host}:sub" = "system:serviceaccount:rhoai-demo:rhoai-s3-sa"
        }
      }
    }]
  })

  tags = merge(var.tags, { Name = "${var.cluster_name}-s3-access" })
}

resource "aws_iam_role_policy" "s3_access" {
  name = "${var.cluster_name}-s3-policy"
  role = aws_iam_role.s3_access.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket"
        ]
        Resource = [
          var.s3_bucket_arn,
          "${var.s3_bucket_arn}/*"
        ]
      }
    ]
  })
}

# ── Bedrock Access Role ─────────────────────────────────────────────────────
resource "aws_iam_role" "bedrock_access" {
  count = var.enable_bedrock_access ? 1 : 0
  name  = "${var.cluster_name}-bedrock-access"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = local.oidc_provider_arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_issuer_host}:sub" = "system:serviceaccount:rhoai-demo:rhoai-bedrock-sa"
        }
      }
    }]
  })

  tags = merge(var.tags, { Name = "${var.cluster_name}-bedrock-access" })
}

resource "aws_iam_role_policy" "bedrock_access" {
  count = var.enable_bedrock_access ? 1 : 0
  name  = "${var.cluster_name}-bedrock-policy"
  role  = aws_iam_role.bedrock_access[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel",
          "bedrock:InvokeModelWithResponseStream",
          "bedrock:ListFoundationModels",
          "bedrock:GetFoundationModel"
        ]
        Resource = ["*"]
      }
    ]
  })
}

# ── ECR Access Role ─────────────────────────────────────────────────────────
resource "aws_iam_role" "ecr_access" {
  name = "${var.cluster_name}-ecr-access"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = local.oidc_provider_arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_issuer_host}:sub" = "system:serviceaccount:rhoai-demo:rhoai-ecr-sa"
        }
      }
    }]
  })

  tags = merge(var.tags, { Name = "${var.cluster_name}-ecr-access" })
}

resource "aws_iam_role_policy" "ecr_access" {
  name = "${var.cluster_name}-ecr-policy"
  role = aws_iam_role.ecr_access.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetAuthorizationToken"
        ]
        Resource = ["*"]
      }
    ]
  })
}

# ── SSM Access Role ─────────────────────────────────────────────────────────
resource "aws_iam_role" "ssm_access" {
  name = "${var.cluster_name}-ssm-access"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = local.oidc_provider_arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_issuer_host}:sub" = "system:serviceaccount:rhoai-demo:rhoai-ssm-sa"
        }
      }
    }]
  })

  tags = merge(var.tags, { Name = "${var.cluster_name}-ssm-access" })
}

resource "aws_iam_role_policy" "ssm_access" {
  name = "${var.cluster_name}-ssm-policy"
  role = aws_iam_role.ssm_access.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:GetParameters",
          "ssm:GetParametersByPath"
        ]
        Resource = ["arn:aws:ssm:${var.aws_region}:*:parameter/${var.ssm_path_prefix}/*"]
      }
    ]
  })
}
