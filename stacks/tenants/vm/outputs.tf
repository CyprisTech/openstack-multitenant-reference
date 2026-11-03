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
