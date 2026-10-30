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

output "svc_public_source_ips" {
  description = "Addresses the edge uses on svc_public. Backends admit them on their published ports (ADR-0001, D7)."
  value       = [for ip in data.openstack_networking_router_v2.svc_public.external_fixed_ip : ip.ip_address]
}

output "routes" {
  description = "Domains currently routed by the entry point."
  value       = sort(keys(var.routes))
}

output "bastion" {
  description = "Floating IP of the bastion on the administration network, or null."
  value       = local.with_bastion ? module.edge.instances[local.bastion_name].ports["admin"].floating_ip : null
}

output "monitoring_targets" {
  description = "Instances exposed to the monitoring collector: floating IP on the monitoring plane and DNS name (or null)."
  value = {
    for name in local.instances : name => {
      address = module.edge.instances[name].ports["main"].floating_ips["monitoring"]
      fqdn    = var.monitoring.dns_zone == null ? null : "${name}.${var.monitoring.dns_zone}"
    }
  }
}
