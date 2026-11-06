output "load_balancer" {
  description = "Virtual IP, public floating IP and DNS names of the entry point."
  value       = module.edge.load_balancers[local.prefix]
}

output "instances" {
  description = "Traefik instances and their addresses on the edge network."
  value = {
    for name in local.instances : name => module.edge.instances[name].ports["main"].ip
  }
}

output "publication_sources" {
  description = "Ranges the entry point connects from on publication, in CIDR notation: the router's gateway address in gateway mode, the entry point's range in interface mode. Backends admit them on their published ports (ADR-0001, D7); pass them to the tenant stacks (edge_sources)."
  value = module.planes.nat.publication ? [
    for ip in data.openstack_networking_router_v2.publication[0].external_fixed_ip : "${ip.ip_address}/32"
  ] : [var.edge_cidr]
}

output "domains" {
  description = "Domains currently routed by the entry point."
  value       = sort(keys(var.domains))
}

output "bastion" {
  description = "Floating IP of the bastion on the administration network, or null."
  value       = var.bastion != null ? module.edge.instances[local.bastion_name].ports["admin"].floating_ip : null
}

