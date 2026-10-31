# Finds the address Neutron gave each attached router on its plane. The plane's owner sees every
# port on it, so the hub lists the router interfaces of each attached project there. No resource.
#
# The plane is read by the range of its subnet, not through the resources that create it: on the
# first apply it does not exist yet, nothing is attached, and the keys below must still be known
# when planning. Then nothing is found, and the next apply finds the attached routers. The range,
# unlike a name, never changes.

data "openstack_networking_subnet_ids_v2" "plane" {
  for_each = var.planes

  cidr      = each.value
  tenant_id = var.hub_project_id
}

data "openstack_networking_subnet_v2" "plane" {
  for_each = { for k, d in data.openstack_networking_subnet_ids_v2.plane : k => d.ids[0] if length(d.ids) == 1 }

  subnet_id = each.value
}

data "openstack_networking_port_ids_v2" "attachment" {
  for_each = { for k, a in var.attachments : k => a if contains(keys(data.openstack_networking_subnet_v2.plane), a.plane) }

  network_id   = data.openstack_networking_subnet_v2.plane[each.value.plane].network_id
  project_id   = each.value.project_id
  device_owner = "network:router_interface"
}

data "openstack_networking_port_v2" "attachment" {
  for_each = { for k, d in data.openstack_networking_port_ids_v2.attachment : k => d.ids[0] if length(d.ids) > 0 }

  port_id = each.value
}
