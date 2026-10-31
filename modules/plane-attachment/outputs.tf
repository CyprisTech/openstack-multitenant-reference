output "mode" {
  description = "Mode of each plane: gateway or interface."
  value       = { for k, p in local.plane : k => p.mode }
}

output "nat" {
  description = "Per plane: true when the instances are reached through floating IPs of the plane, false at their own addresses."
  value       = local.nat
}

output "network_name" {
  description = "Name of each plane's network (a floating IP pool, for nat planes)."
  value       = { for k, p in local.plane : k => p.network_name }
}

output "cidr" {
  description = "Range of each plane."
  value       = { for k, p in local.plane : k => p.cidr }
}

output "networks" {
  description = "Planes to adopt, for tenant.existing.networks, by ID."
  value       = { for k, p in local.plane : k => { id = p.network_id, subnets = { main = { id = p.subnet_id } } } }
}

output "routers" {
  description = "One router per plane, keyed by the plane name with dashes (svc-public, monitoring), for tenant.networks.<network>.routers."
  value = {
    for k, p in local.plane : replace(k, "_", "-") => {
      internal_subnet  = var.internal_subnet
      external_network = local.interface[k] ? null : k
      interfaces       = { for i in(local.interface[k] ? ["plane"] : []) : i => { network = k, subnet = "main" } }
      routes           = local.interface[k] ? p.routes : []
      default_gateway  = var.default_gateway == k ? true : null
      advertise_routes = var.default_gateway == k ? [] : distinct(concat([p.cidr], [for r in p.routes : r.destination if local.interface[k]]))
    }
  }
}

output "ports" {
  description = "Exposure of each instance's port, keyed by instance: floating_ip, extra_floating_ips and dns attributes of the tenant model."
  value = {
    for name in var.instances : name => {
      floating_ip = var.exposure.primary != null && try(local.nat[var.exposure.primary], false) ? {
        pool = var.exposure.primary
        dns  = try(var.exposure.dns.plane, null) == var.exposure.primary ? [{ name = name, zone = var.exposure.dns.zone }] : []
      } : null
      extra_floating_ips = {
        for p in var.exposure.extra : p => {
          pool = p
          dns  = try(var.exposure.dns.plane, null) == p ? [{ name = name, zone = var.exposure.dns.zone }] : []
        } if local.nat[p]
      }
      dns = var.exposure.dns != null && !try(local.nat[var.exposure.dns.plane], true) ? [{ name = name, zone = var.exposure.dns.zone }] : []
    }
  }
}
