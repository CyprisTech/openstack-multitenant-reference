# Ingress rules of a security group written as flows: "these sources may reach these ports"
# (TCP unless the flow says udp).
# One rule per flow, port and source, keyed <flow>-<port>-<source>, for the rules of a security
# group in the tenant model of terraform-openstack-tenant. No resource: the stack puts the rules
# in its security groups.

locals {
  rules = merge([
    for flow, a in var.allow : {
      for pair in setproduct(distinct(a.ports), distinct(a.sources)) : "${flow}-${pair[0]}-${replace(pair[1], "/", "_")}" => {
        direction = "ingress", protocol = a.protocol, port_min = pair[0], port_max = pair[0], remote_ip_prefix = pair[1]
      }
    }
  ]...)
}
