# How a stack joins the shared planes (ADR-0003, D2), computed once for every stack: the planes
# to adopt, the plane routers, and how instances are exposed. No resource: the outputs are
# fragments of the tenant model of terraform-openstack-tenant.
#
# Each plane is described by stack shared/planes, with two properties:
# - mode: how the router joins it. gateway: the router's gateway is on the plane (an operator's
#   external network). interface: an interface on the plane, and routes through the plane's
#   transit router (a private network of a hub, shared by RBAC).
# - nat: whether the tenant's addresses are translated there. true: instances are reached
#   through floating IPs of the plane. false: at their own addresses.
# The instances learn the plane's range, and every range routed through it, by DHCP.

locals {
  plane     = { for k in var.planes : k => var.attachment[k] }
  interface = { for k, p in local.plane : k => p.mode == "interface" }
  nat       = { for k, p in local.plane : k => p.nat }
}
