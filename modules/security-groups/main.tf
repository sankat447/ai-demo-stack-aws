# =============================================================================
#  Security Groups for OCP nodes, Aurora, EFS, and Ingress/LB
# =============================================================================

# ── OCP Nodes SG ────────────────────────────────────────────────────────────
resource "aws_security_group" "ocp_nodes" {
  name_prefix = "${var.name}-ocp-nodes-"
  description = "Security group for OCP master and worker nodes"
  vpc_id      = var.vpc_id

  # All traffic between cluster nodes
  ingress {
    description = "Inter-node communication"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    self        = true
  }

  # Kubernetes API server
  ingress {
    description = "Kubernetes API"
    from_port   = 6443
    to_port     = 6443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  # Machine config server
  ingress {
    description = "Machine config server"
    from_port   = 22623
    to_port     = 22623
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  # etcd
  ingress {
    description = "etcd"
    from_port   = 2379
    to_port     = 2380
    protocol    = "tcp"
    self        = true
  }

  # NodePort services
  ingress {
    description = "NodePort services"
    from_port   = 30000
    to_port     = 32767
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  # VXLAN for OVN-Kubernetes
  ingress {
    description = "VXLAN"
    from_port   = 4789
    to_port     = 4789
    protocol    = "udp"
    self        = true
  }

  # Geneve for OVN-Kubernetes
  ingress {
    description = "Geneve"
    from_port   = 6081
    to_port     = 6081
    protocol    = "udp"
    self        = true
  }

  # IPsec IKE
  ingress {
    description = "IPsec IKE"
    from_port   = 500
    to_port     = 500
    protocol    = "udp"
    self        = true
  }

  # IPsec NAT-T
  ingress {
    description = "IPsec NAT-T"
    from_port   = 4500
    to_port     = 4500
    protocol    = "udp"
    self        = true
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, {
    Name = "${var.name}-ocp-nodes"
  })

  lifecycle {
    create_before_destroy = true
  }
}

# Aurora and EFS SGs are defined in environments/demo/main.tf — they live
# in the OCP-installer VPC (data.aws_vpc.ocp), not the Terraform VPC.
# Cross-VPC peering is impossible (both have CIDR 10.0.0.0/16), so Aurora/EFS
# must be in the same VPC as the cluster nodes.

# ── Ingress / Load Balancer SG ──────────────────────────────────────────────
resource "aws_security_group" "ingress_lb" {
  name_prefix = "${var.name}-ingress-lb-"
  description = "Ingress and load balancer access"
  vpc_id      = var.vpc_id

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, {
    Name = "${var.name}-ingress-lb"
  })

  lifecycle {
    create_before_destroy = true
  }
}
