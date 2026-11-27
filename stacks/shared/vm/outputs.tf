output "services" {
  description = "What the consumers reach, on the internal services plane: each service and its \"address:port\" entries, at a floating IP of the plane with NAT, at its address in the service's network otherwise. The consumers admit nothing from the service for them."
  value       = { for k, s in var.services : k => [for p in s.ports : "${local.addresses[k]}:${p}"] }
}

output "domains" {
  description = "Names of the services and the address they resolve to; as records, in dns_records."
  value       = merge([for k, s in var.services : { for d in s.domains : d => local.addresses[k] }]...)
}

output "dns_records" {
  description = "The records of the domains of services in internal_zone (ADR-0016, D2), keyed \"<name> <type>\", each { zone, name, type, ttl, records }: written in Designate with dns = \"designate\", to publish with your DNS provider otherwise (a for_each of its record resource). Empty without internal_zone."
  value       = { for d, r in local.records : "${d} ${r.type}" => merge(r, { zone = var.internal_zone.name }) }
}

output "sources" {
  description = "Addresses the service connects from on the internal services plane, for the admission rules of what it calls (allowed_sources): its router's gateway address on a plane with NAT, its range on a plane without NAT."
  value = { internal = local.nat ? [
    for ip in data.openstack_networking_router_v2.internal[0].external_fixed_ip : "${ip.ip_address}/32"
  ] : [var.cidr] }
}

data "openstack_networking_router_v2" "internal" {
  count     = try(module.planes.nat.internal, false) ? 1 : 0
  router_id = module.service.networks[local.prefix].routers["internal"].id
}

output "instances" {
  description = "Instances and their private addresses."
  value       = { for name in local.instances : name => module.service.instances[name].ports["main"].ip }
}

output "bastion" {
  description = "Floating IP of the bastion on the administration network, or null."
  value       = var.bastion != null ? module.service.instances[local.bastion_name].ports[module.bastion.floating_ip_port].floating_ip : null
}
