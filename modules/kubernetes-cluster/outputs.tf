output "bootstrap" {
  description = "Floating IP of the bootstrap instance on the administration network, or null once it is removed."
  value       = var.bootstrap ? module.tenant.instances[local.instance].ports["main"].floating_ip : null
}

output "sources" {
  description = "Addresses the cluster connects from on each plane it joins, for the admission rules of what it calls there (allowed_sources): its router's gateway address on a plane with NAT, the cluster range on a plane without NAT."
  value = { for p in var.planes : p => module.planes.nat[p] ? [
    for ip in data.openstack_networking_router_v2.plane[p].external_fixed_ip : "${ip.ip_address}/32"
  ] : [var.cluster_cidr] }
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

output "entries" {
  description = "Address of each entry, keyed like the ingresses and the services inputs: a floating IP of its plane with NAT, its address in the cluster network otherwise."
  value = merge(
    { for k in keys(var.ingresses) : k => local.entry_address[k] },
    { for k in keys(var.services) : k => local.entry_address["service-${k}"] },
  )
}

data "openstack_networking_router_v2" "plane" {
  for_each  = toset([for p in var.planes : p if module.planes.nat[p]])
  router_id = module.tenant.networks[local.network].routers[each.key].id
}
