output "zone_id" {
  description = "Route53 hosted zone ID"
  value       = data.aws_route53_zone.cluster.zone_id
}

output "name_servers" {
  description = "Route53 name servers (delegate these from your registrar)"
  value       = data.aws_route53_zone.cluster.name_servers
}
