output "bootstrap" {
  description = "Floating IP of the bootstrap instance on the administration network, or null once it is removed."
  value       = var.bootstrap ? module.platform.instances[local.instance].ports["main"].floating_ip : null
}

output "edge_sources" {
  description = "Addresses of the entry point admitted by the ingress load balancer."
  value       = var.edge_sources
}

output "internal_sources" {
  description = "Addresses the cluster reaches the internal services plane from, for the services of that plane (allowed_sources): its router's gateway address on a plane with NAT, the cluster range on a plane without NAT."
  value = module.planes.nat.internal ? [
    for ip in data.openstack_networking_router_v2.internal[0].external_fixed_ip : "${ip.ip_address}/32"
  ] : [var.cluster_cidr]
}

output "manifests" {
  description = "Rendered Cluster API manifests, as written on the bootstrap instance. Sensitive with certificates (the DNS provider's key)."
  sensitive   = true
  value       = local.manifests
}

output "scripts" {
  description = "Rendered create and delete scripts, as written on the bootstrap instance (cloud-init writes them once: copy them again after a change)."
  sensitive   = true
  value       = local.scripts
}

output "published_domains" {
  description = "Domains to publish through the entry point and the tenant's service address, its ingress (ADR-0006, D1): a floating IP of publication when the plane translates addresses, the load balancer address otherwise. For the domains input of the entry point (scripts/publish-domains.sh)."
  value       = { for d in var.cluster.domains : d => { backends = ["${local.ingress_address}:443"] } }
}


data "openstack_networking_router_v2" "internal" {
  count     = module.planes.nat.internal ? 1 : 0
  router_id = module.platform.networks[local.network].routers["internal"].id
}
