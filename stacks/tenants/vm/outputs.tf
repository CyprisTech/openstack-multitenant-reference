output "service_address" {
  description = "The tenant's service address, \"address:443\" (ADR-0006, D1): its load balancer, or its only instance. On svc_public through the entry point (a floating IP of the plane when it translates addresses, the address itself otherwise), or a public floating IP with exposure = \"public\"."
  value       = local.service_address
}

output "published_domains" {
  description = "Domains to publish through the entry point and their service address, for its domains input (scripts/publish-domains.sh). Empty with exposure = \"public\"."
  value       = local.public ? {} : { for d in var.domains : d => { backends = [local.service_address] } }
}

output "edge_sources" {
  description = "Addresses of the entry point admitted on the service address."
  value       = local.edge_sources
}

output "instances" {
  description = "Web instances and their private addresses."
  value       = { for name in local.instances : name => module.web.instances[name].ports["main"].ip }
}

output "bastion" {
  description = "Floating IP of the bastion on the administration network, or null."
  value       = var.bastion != null ? module.web.instances[local.bastion_name].ports["admin"].floating_ip : null
}


locals {
  service_address = "${local.load_balancer ? (
    local.public || module.planes.nat.svc_public ? module.web.load_balancers[local.prefix].floating_ip : module.web.load_balancers[local.prefix].vip
    ) : (
    local.public || module.planes.nat.svc_public ? module.web.instances[local.instances[0]].ports["main"].floating_ip : module.web.instances[local.instances[0]].ports["main"].ip
  )}:443"
}

output "intranet_sources" {
  description = "Addresses the tenant reaches the internal services plane from, for the services of that plane (allowed_sources): its router's gateway address on an operator plane, the tenant range on an interface plane. Empty when the tenant does not join the plane."
  value = !contains(keys(var.plane_attachment), "intranet") ? [] : module.planes.nat.intranet ? [
    for ip in data.openstack_networking_router_v2.intranet[0].external_fixed_ip : "${ip.ip_address}/32"
  ] : [var.web_cidr]
}

data "openstack_networking_router_v2" "intranet" {
  count     = contains(keys(var.plane_attachment), "intranet") && try(module.planes.nat.intranet, false) ? 1 : 0
  router_id = module.web.networks[local.prefix].routers["intranet"].id
}
