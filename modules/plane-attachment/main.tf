# How a stack joins the shared planes (ADR-0004), computed once for every stack: the planes
# to adopt, the plane routers, and how instances are exposed. No resource: the outputs are
# fragments of the tenant model of terraform-openstack-tenant.
#
# Each plane is described by stack shared/planes, with two properties:
# - mode: how the router joins it. gateway: the router's gateway is on the plane (an operator's
#   external network). interface: an interface on the plane, and routes through the plane's
#   transit router (a private network of a hub, shared by RBAC).
# - nat: whether the tenant's addresses are translated there. true: instances are reached
#   through floating IPs of the plane. false: at their own addresses.
#
# Routing (ADR-0013): the subnet gets one gateway, a transit router
# with no external gateway. It holds a static route to each plane's range, and to every range
# routed through the plane, via the plane's router; the default route goes to the default
# router: the egress router, or a plane's router for a tenant with no egress. The subnet
# carries no host routes: Octavia load balancers copy them once, when their VIP is plugged,
# and would miss any later change.

locals {
  plane     = { for k in var.planes : k => var.attachment[k] }
  interface = { for k, p in local.plane : k => p.mode == "interface" }
  nat       = { for k, p in local.plane : k => p.nat }

  # Router keys in the stack's network: the plane's name, with dashes.
  router_key = { for k in var.planes : k => replace(k, "_", "-") }

  # Routes of the transit router: each plane's destinations via its router, the stack's own
  # destinations via their routers, then the default route via the default router.
  transit_routes = concat(
    flatten([for k, p in local.plane : [
      for d in distinct(concat([p.cidr], [for r in p.routes : r.destination if local.interface[k]])) :
      { destination = d, next_hop_router = local.router_key[k] }
    ]]),
    flatten([for rk, ds in var.routes : [for d in ds : { destination = d, next_hop_router = rk }]]),
    var.default_router == null ? [] : [{ destination = "0.0.0.0/0", next_hop_router = lookup(local.router_key, var.default_router, var.default_router) }],
  )
}
