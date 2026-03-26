# =============================================================================
#  Route53 Hosted Zone for OCP cluster domain
#  OCP IPI installer requires a hosted zone matching the base_domain
# =============================================================================

resource "aws_route53_zone" "cluster" {
  name          = var.base_domain
  comment       = "AI Demo Stack - OCP cluster domain"
  force_destroy = true

  tags = merge(var.tags, {
    Name = "${var.name}-dns"
  })
}
