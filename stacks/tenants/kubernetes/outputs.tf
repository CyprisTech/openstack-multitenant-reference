output "bootstrap" {
  description = "Floating IP of the bootstrap instance on the administration network, or null once it is removed."
  value       = module.cluster.bootstrap
}

output "service_address" {
  description = "The tenant's service address, \"address:443\" (ADR-0006, D1): its ingress. On publication through the entry point (a floating IP of the plane when it translates addresses, the load balancer address otherwise), or a public floating IP with exposure = \"public\"."
  value       = "${module.cluster.entries.public}:443"
}

output "edge_sources" {
  description = "Addresses of the entry point admitted by the ingress load balancer. Empty with exposure = \"public\"."
  value       = local.public ? [] : var.edge_sources
}

output "internal_sources" {
  description = "Addresses the cluster reaches the internal services plane from, for the services of that plane (allowed_sources): its router's gateway address on a plane with NAT, the cluster range on a plane without NAT. Empty when the cluster does not join the plane."
  value       = lookup(module.cluster.sources, "internal", [])
}

output "manifests" {
  description = "Rendered Cluster API manifests, as written on the bootstrap instance. Sensitive with certificates (the DNS provider's key)."
  sensitive   = true
  value       = module.cluster.manifests
}

output "scripts" {
  description = "Rendered create and delete scripts, as written on the bootstrap instance (cloud-init writes them once: copy them again after a change)."
  sensitive   = true
  value       = module.cluster.scripts
}

output "published_domains" {
  description = "Domains to publish through the entry point and the tenant's service address, its ingress (ADR-0006, D1): a floating IP of publication when the plane translates addresses, the load balancer address otherwise. For the domains input of the entry point (scripts/publish-domains.sh). Empty with exposure = \"public\"."
  value       = local.public ? {} : { for d in var.cluster.domains : d => { backends = ["${module.cluster.entries.public}:443"] } }
}
