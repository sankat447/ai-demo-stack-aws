output "ocp_nodes_sg_id" {
  description = "Security group ID for OCP nodes"
  value       = aws_security_group.ocp_nodes.id
}

output "aurora_sg_id" {
  description = "Security group ID for Aurora"
  value       = aws_security_group.aurora.id
}

output "efs_sg_id" {
  description = "Security group ID for EFS"
  value       = aws_security_group.efs.id
}

output "ingress_lb_sg_id" {
  description = "Security group ID for ingress/LB"
  value       = aws_security_group.ingress_lb.id
}
