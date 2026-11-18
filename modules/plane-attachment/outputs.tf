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
  description = "For tenant.networks.<network>.routers: one router per plane, keyed by the plane name (publication, observability), and the transit router, gateway of the subnet, holding the routes to the planes."
  value = merge({
    for k, p in local.plane : local.router_key[k] => {
      internal_subnet  = var.internal_subnet
      external_network = local.interface[k] ? null : k
      interfaces       = { for i in(local.interface[k] ? ["plane"] : []) : i => { network = k, subnet = "main" } }
      routes           = local.interface[k] ? p.routes : []
    }
    }, {
    transit = {
      internal_subnet = var.internal_subnet
      default_gateway = true
      routes          = local.transit_routes
    }
  })
}

output "ports" {
  description = "Exposure of each instance's port, keyed by instance: the floating_ip attribute of the tenant model (a floating IP of the primary plane when it translates addresses, null otherwise)."
  value = {
    for name in var.instances : name => {
      floating_ip = var.exposure.primary != null && try(local.nat[var.exposure.primary], false) ? { pool = var.exposure.primary } : null
    }
  }
}
