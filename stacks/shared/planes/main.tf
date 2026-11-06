# Shared planes (ADR-0004), applied with the hub project's credentials. Read from top to
# bottom:
#   1. operator planes (gateway mode): adopted, nothing created;
#   2. shared private planes (interface mode): a network per plane with its transit router,
#      shared with the attached projects;
#   3. who routes to whom: every attached router routes through the transit router;
#   4. the transit router routes back to every attached router, at the address discovered;
#   5. checks.

locals {
  prefix           = var.site
  interface_planes = { for k, p in var.planes : k => p if p.mode == "interface" }
  plane_name       = { for k in keys(local.interface_planes) : k => "${local.prefix}-${replace(k, "_", "-")}" }

  # The transit router holds the plane's first address, as its gateway: the only fixed address on
  # the plane, chosen by the hub (a project cannot choose its address on a network it does not own).
  transit_ip = { for k, p in local.interface_planes : k => cidrhost(p.cidr, 1) }

  # One entry per attachment and hub plane.
  joins = merge([
    for ak, a in var.attachments : {
      for pk in keys(a.planes) : "${ak}/${pk}" => { attachment = ak, plane = pk, project_id = a.project_id }
      if var.planes[pk].mode == "interface"
    }
  ]...)
}

# 1. Operator planes ----------------------------------------------------------------------------

data "openstack_networking_network_v2" "operator" {
  for_each = { for k, p in var.planes : k => p if p.mode == "gateway" }

  name     = each.value.network
  external = true
}

data "openstack_networking_subnet_v2" "operator" {
  for_each = { for k, p in var.planes : k => p if p.mode == "gateway" }

  name       = each.value.subnet
  network_id = data.openstack_networking_network_v2.operator[each.key].id
}

# 2. Shared private planes ----------------------------------------------------------------------

# The plane and its transit router: a router on the plane's subnet, holding its gateway address.
# No DHCP: the plane only carries router interfaces.
module "plane" {
  source   = "git::https://github.com/CyprisTech/terraform-openstack-tenant.git//modules/network?ref=v0.1.4"
  for_each = local.interface_planes

  name = local.plane_name[each.key]
  mtu  = each.value.mtu
  subnets = {
    main = {
      cidr             = each.value.cidr
      gateway_ip       = local.transit_ip[each.key]
      allocation_pools = [{ start = cidrhost(each.value.cidr, 2), end = cidrhost(each.value.cidr, -2) }] # for the attached routers
      enable_dhcp      = false
    }
  }
  routers = { transit = { internal_subnet = "main", default_gateway = true } }
}

# Network and subnet of every plane, wherever it comes from.
locals {
  plane_network = {
    for k, p in var.planes : k => p.mode == "interface"
    ? { id = module.plane[k].id, name = module.plane[k].name }
    : { id = data.openstack_networking_network_v2.operator[k].id, name = data.openstack_networking_network_v2.operator[k].name }
  }
  plane_subnet_id = {
    for k, p in var.planes : k => p.mode == "interface" ? module.plane[k].subnets["main"].id : data.openstack_networking_subnet_v2.operator[k].id
  }
}

resource "openstack_networking_rbac_policy_v2" "plane" {
  for_each = local.joins

  action        = "access_as_shared"
  object_type   = "network"
  object_id     = module.plane[each.value.plane].id
  target_tenant = each.value.project_id
}

# 3. Who routes to whom --------------------------------------------------------------------------

locals {
  # Ranges the shared services of a plane reach: its tenants, or their aggregates when given
  # (then a new tenant inside them changes no shared service).
  tenant_ranges = {
    for pk in keys(local.interface_planes) : pk => coalesce(lookup(var.tenant_ranges, pk, null), [
      for a in values(var.attachments) : a.cidr if lookup(a.planes, pk, null) == "tenant"
    ])
  }

  # Routes of each attached router, all through the transit router, known before the attachment
  # exists: a tenant reaches the shared services of the plane; a shared service reaches the
  # other shared services and the tenants. Never a tenant to another.
  routes = {
    for ak, a in var.attachments : ak => {
      for pk in keys(a.planes) : pk => [
        for d in distinct(concat(
          [for bk, b in var.attachments : b.cidr if bk != ak && lookup(b.planes, pk, null) == "shared"],
          a.planes[pk] == "shared" ? local.tenant_ranges[pk] : [],
        )) : { destination = d, next_hop = local.transit_ip[pk] }
      ] if var.planes[pk].mode == "interface"
    }
  }
}

# 4. The transit router routes back to every attached router ------------------------------------

data "openstack_identity_auth_scope_v3" "hub" {
  name = "hub"
}

module "discovery" {
  source = "../../../modules/plane-discovery"

  hub_project_id = data.openstack_identity_auth_scope_v3.hub.project_id
  planes         = { for k, p in local.interface_planes : k => p.cidr }
  attachments    = local.joins
}

resource "openstack_networking_router_route_v2" "transit" {
  for_each = module.discovery.addresses

  router_id        = module.plane[local.joins[each.key].plane].routers["transit"].id
  destination_cidr = var.attachments[local.joins[each.key].attachment].cidr
  next_hop         = each.value

  lifecycle {
    precondition {
      condition     = module.discovery.interface_counts[each.key] == 1
      error_message = "Attachment ${each.key}: its project has several router interfaces on the plane; one is expected."
    }
  }
}

# 5. Checks --------------------------------------------------------------------------------------

# Planes overlap nothing; attachments of a hub plane do not overlap each other (on
# planes with NAT they may: they are never seen there).
module "overlaps" {
  source = "../../../modules/range-overlaps"

  ranges = merge(
    { for k, p in var.planes : "plane ${k}" => { cidr = p.cidr, scopes = ["*"] } },
    { for k, a in var.attachments : "attachment ${k}" => { cidr = a.cidr, scopes = [for p in keys(a.planes) : p if var.planes[p].mode == "interface"] } },
  )
}

resource "terraform_data" "checks" {
  lifecycle {
    precondition {
      condition     = length(module.overlaps.overlaps) == 0
      error_message = "Overlapping ranges: ${join("; ", module.overlaps.overlaps)}."
    }
    precondition {
      condition     = alltrue([for j in values(local.joins) : j.project_id != data.openstack_identity_auth_scope_v3.hub.project_id])
      error_message = "The hub project holds the network only: attach shared services from their own projects."
    }
  }
}
