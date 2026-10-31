output "addresses" {
  description = "IPv4 address of each attached router on its plane, keyed like attachments; attachments not joined yet are absent."
  value = {
    for k, p in data.openstack_networking_port_v2.attachment : k => [for ip in p.all_fixed_ips : ip if !strcontains(ip, ":")][0]
  }
}

output "interface_counts" {
  description = "Number of router interfaces each attached project has on its plane; one is expected."
  value       = { for k, d in data.openstack_networking_port_ids_v2.attachment : k => length(d.ids) }
}
