output "planes" {
  description = "Planes keyed like the input: { mode, cidr, network_id, subnet_id }."
  value = {
    for k, p in var.planes : k => {
      mode       = p.mode
      cidr       = p.cidr
      network_id = local.plane_network[k].id
      subnet_id  = local.plane_subnet_id[k]
    }
  }
}

output "attachments" {
  description = <<-EOT
    The plane_attachment input of each attached stack, keyed like the input: for every plane it
    joins, how its router joins it (mode: gateway or interface), whether its addresses are
    translated there (nat: floating IPs) or seen as they are, the plane's network and subnet,
    and the router routes (through the transit router, hub planes only). The same shape
    for operator planes and for planes built here: the stacks do not depend on where the planes
    come from.
  EOT
  value = {
    for ak, a in var.attachments : ak => {
      planes = { for pk in keys(a.planes) : pk => {
        mode         = var.planes[pk].mode
        nat          = var.planes[pk].mode == "gateway"
        cidr         = var.planes[pk].cidr
        network_id   = local.plane_network[pk].id
        network_name = local.plane_network[pk].name
        subnet_id    = local.plane_subnet_id[pk]
        routes       = var.planes[pk].mode == "interface" ? local.routes[ak][pk] : []
      } }
    }
  }
  depends_on = [openstack_networking_rbac_policy_v2.plane]
}

output "transit" {
  description = "Transit router of each hub plane: its address, and the attachments it routes to (address Neutron gave their router on the plane)."
  value = {
    for pk, ip in local.transit_ip : pk => {
      address = ip
      routes  = { for k, ip in module.discovery.addresses : local.joins[k].attachment => "${var.attachments[local.joins[k].attachment].cidr} via ${ip}" if local.joins[k].plane == pk }
    }
  }
}
