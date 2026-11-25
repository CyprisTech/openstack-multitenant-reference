output "bootstrap" {
  description = "Floating IP of the bootstrap instance on the administration network, or null once it is removed."
  value       = module.cluster.bootstrap
}

output "service_address" {
  description = "The tenant's service address, \"address:443\" (ADR-0006, D1): its ingress. On publication through the entry point (a floating IP of the plane when it translates addresses, the load balancer address otherwise), or a public floating IP with exposure = \"public\". null with exposure = \"none\"."
  value       = local.exposed ? "${module.cluster.entries.public}:443" : null
}

output "services" {
  description = "The public addresses of the layer 4 services of the services input, \"address:port\" for each port."
  value       = { for k, s in var.services : k => [for p in s.ports : "${module.cluster.entries[k]}:${p}"] }
}

output "edge_sources" {
  description = "Addresses of the entry point admitted by the ingress load balancer. Empty with exposure = \"public\" or \"none\"."
  value       = var.exposure == "entry-point" ? var.edge_sources : []
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
  description = "Rendered scripts: create-cluster.sh and delete-cluster.sh, written on the bootstrap instance at its creation; update-cluster.sh, run from the administration sources after each apply (scripts/cluster-files.sh writes them in a directory)."
  sensitive   = true
  value       = module.cluster.scripts
}

output "published_domains" {
  description = "Domains to publish through the entry point and the tenant's service address, its ingress (ADR-0006, D1): a floating IP of publication when the plane translates addresses, the load balancer address otherwise. For the domains input of the entry point (scripts/request-domains.sh). Empty with exposure = \"public\" or \"none\"."
  value       = var.exposure == "entry-point" ? { for d in var.cluster.domains : d => { backends = ["${module.cluster.entries.public}:443"] } } : {}
}
