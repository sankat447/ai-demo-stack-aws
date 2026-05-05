output "ocp_nodes_sg_id" {
  description = "Security group ID for OCP nodes"
  value       = aws_security_group.ocp_nodes.id
}

# Aurora and EFS SGs were removed when both moved to the OCP VPC. The
# OCP-VPC SGs (aurora_ocp / efs_ocp) are defined directly in
# environments/demo/main.tf because they need data.aws_vpc.ocp.

output "ingress_lb_sg_id" {
  description = "Security group ID for ingress/LB"
  value       = aws_security_group.ingress_lb.id
}
