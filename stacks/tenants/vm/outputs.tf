output "backends" {
  description = "Published backends (\"address:443\"): floating IPs on svc_public in gateway mode, the instances' own addresses in interface mode. Published through the entry point (output published_domains)."
  value       = local.backends
}

output "published_domains" {
  description = "Domains served by this tenant and their backends, for the domains input of the entry point (scripts/publish-domains.sh)."
  value       = { for d in var.domains : d => { backends = local.backends } }
}

output "edge_sources" {
  description = "Addresses of the entry point admitted on port 443."
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

output "monitoring_targets" {
  description = "Instances exposed to the monitoring collector: floating IP on the monitoring plane and DNS name (or null)."
  value = {
    for name in local.instances : name => {
      address = !module.planes.nat.monitoring ? module.web.instances[name].ports["main"].ip : module.web.instances[name].ports["main"].floating_ips["monitoring"]
      fqdn    = var.monitoring.dns_zone == null ? null : "${name}.${var.monitoring.dns_zone}"
    }
  }
}

locals {
  backends = [
    for name in local.instances : "${!module.planes.nat.svc_public ? module.web.instances[name].ports["main"].ip : module.web.instances[name].ports["main"].floating_ip}:443"
  ]
}
