# =============================================================================
#  Route53 Hosted Zone for OCP cluster domain
#  OCP IPI installer requires a hosted zone matching the base_domain
#  Use the EXISTING registrar-created zone — do NOT create a duplicate
# =============================================================================

data "aws_route53_zone" "cluster" {
  name         = var.base_domain
  private_zone = false
}
