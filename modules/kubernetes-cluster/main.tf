# A Kubernetes cluster created by Cluster API with the OpenStack provider (ADR-0002), common to
# the stacks that deploy one. Terraform prepares the infrastructure of the project (D1): the cluster
# network with its routers to the planes, the server groups of the machines and the bootstrap
# instance. The cluster itself is described by the manifests of manifests/, rendered here and
# written on the bootstrap instance, where scripts/create-cluster.sh applies them.
#
# Terraform never handles the OpenStack credentials of the cluster: the operator copies a
# clouds.yaml to the bootstrap instance (see README.md), so they stay out of the state and of
# the instance metadata.

locals {
  prefix   = var.name
  network  = local.prefix
  subnet   = "${local.prefix}-main"
  router   = local.admin_on_internal ? "${local.prefix}-internal" : "${local.prefix}-admin"
  instance = "${local.prefix}-bootstrap"

  admin_on_internal = var.admin_network == null
  admin_network     = local.admin_on_internal ? { network = try(module.planes.network_name.internal, null) } : { network = var.admin_network.network }

  # The entries of the cluster (ADR-0006, D1): each one at a floating IP of its plane when the
  # plane translates addresses, at a fixed address of the cluster network otherwise. An entry
  # with plane "egress" is exposed directly (ADR-0006, D2): a floating IP of egress_network,
  # the external network of the cluster's default route, so that replies leave the same way.
  ingresses = { for k, i in var.ingresses : k => merge(i, {
    namespace  = coalesce(i.namespace, "traefik-${k}")
    tls_secret = coalesce(i.tls_secret, "${k}-tls")
  }) }
  entries = merge(
    { for k, i in var.ingresses : k => { plane = i.plane, host = i.host } },
    { for k, s in var.services : "service-${k}" => { plane = s.plane, host = s.host } },
  )
  egress_entries = { for k, e in local.entries : k => e if e.plane == "egress" }
  entry_nat      = { for k, e in local.entries : k => e.plane == "egress" ? true : module.planes.nat[e.plane] }
  entry_network = { for k, e in local.entries : k => e.plane == "egress" ? {
    name = var.egress_network.network, id = data.openstack_networking_network_v2.egress[0].id
    } : {
    name = module.planes.network_name[e.plane], id = var.plane_attachment[e.plane].network_id
  } }
  entry_address = { for k, e in local.entries : k => local.entry_nat[k] ? openstack_networking_floatingip_v2.entry[k].address : cidrhost(var.cluster_cidr, e.host) }
  # The first host numbers are kept for the entries on planes without NAT.
  fixed_entries = anytrue([for k, n in local.entry_nat : !n])
}

# How the cluster network joins the planes (ADR-0004).
module "planes" {
  source = "../plane-attachment"

  planes     = var.planes
  attachment = var.plane_attachment
}

# Who may reach the bootstrap instance.
module "admission" {
  source = "../admission"

  allow = {
    ssh = { ports = [22], sources = var.admin.sources }
  }
}

# The internal services plane carries the administration role only when it is an operator plane: the API and
# the bootstrap instance need floating IPs.
resource "terraform_data" "checks" {
  lifecycle {
    precondition {
      condition     = !local.admin_on_internal || try(module.planes.nat.internal, false)
      error_message = "Without admin_network, the administration role goes to the internal services plane, which must be joined (planes) and give floating IPs (nat = true): otherwise set admin_network, an external network for the API and bootstrap floating IPs."
    }
    precondition {
      condition     = alltrue([for k, e in local.entries : e.plane == "egress" || contains(var.planes, e.plane)])
      error_message = "The plane of an entry is one of planes, or \"egress\" for an entry exposed directly."
    }
  }
}

# The external network of the default route, for the entries exposed directly.
data "openstack_networking_network_v2" "egress" {
  count    = length(local.egress_entries) > 0 ? 1 : 0
  name     = var.egress_network.network
  external = true
}

# Addresses of the entries on planes with NAT, created here rather than by the cloud controller
# manager: they are known before the cluster exists, they are outputs (the routes of the entry
# point and the consumers' admissions come from them), and they survive the Services. The
# Services request them (spec.loadBalancerIP) and the cloud controller manager never deletes
# them (keep-floatingip).
resource "openstack_networking_floatingip_v2" "entry" {
  for_each = { for k, e in local.entries : k => e if local.entry_nat[k] }

  pool        = local.entry_network[each.key].name
  description = "${local.prefix} ${each.key}"

  # Destroyed before the router interfaces: Neutron does not remove an interface while a
  # floating IP uses it (the cloud controller associates this one to the entry's VIP).
  depends_on = [module.tenant]
}

# An entry on a plane without NAT needs its host number, kept out of the allocation pool.
resource "terraform_data" "entries" {
  lifecycle {
    precondition {
      condition     = alltrue([for k, e in local.entries : local.entry_nat[k] || (e.host != null ? e.host > 1 && e.host < var.reserved_hosts : false)])
      error_message = "An entry on a plane without NAT needs a host number between 2 and reserved_hosts - 1."
    }
  }
}

module "tenant" {
  source = "git::https://github.com/CyprisTech/terraform-openstack-tenant.git?ref=v0.1.5"

  tenant = {
    existing = {
      networks = merge({
        egress = { name = var.egress_network.network, subnets = { main = { name = var.egress_network.subnet } } }
        }, module.planes.networks, {
        for k in(local.admin_on_internal ? [] : ["admin"]) : k => {
          name = var.admin_network.network, subnets = { main = { name = var.admin_network.subnet } }
        }
      })
    }

    networks = {
      (local.network) = {
        mtu = var.network_mtu
        subnets = {
          main = {
            cidr            = var.cluster_cidr
            dns_nameservers = var.dns_nameservers
            # The first addresses are kept for the entries on planes without NAT.
            allocation_pools = local.fixed_entries ? [{
              start = cidrhost(var.cluster_cidr, var.reserved_hosts)
              end   = cidrhost(var.cluster_cidr, -2)
            }] : []
          }
        }
        # One router per plane; only the planes' ranges are routed through them (DHCP routes).
        # The router to the administration network also carries the floating IPs of the API
        # and of the bootstrap instance; CAPO adds its external address to the sources admitted
        # by the API load balancer, since the nodes reach the API through it.
        routers = merge({
          egress = { external_network = "egress", internal_subnet = "main", default_gateway = true }
          }, module.planes.routers, {
          for k in(local.admin_on_internal ? [] : ["admin"]) : k => {
            external_network = "admin", internal_subnet = "main",
            advertise_routes = [var.admin_network.cidr]
          }
        })
      }
    }

    # Read by the machine templates (ADR-0002, D2). Soft anti-affinity: the cluster still
    # starts when the cloud has fewer hosts than machines.
    server_groups = {
      "${local.prefix}-control-plane" = { policy = "soft-anti-affinity" }
      "${local.prefix}-workers"       = { policy = "soft-anti-affinity" }
    }
  }
}

# The cluster network as the bootstrap call adopts it, once the network call is complete (its
# routers carry the bootstrap's floating IP). A managed resource rather than depends_on on the
# call: depends_on would defer the lookups of the bootstrap call at every change of the network,
# and replace the instance. Its output stays known once created.
resource "terraform_data" "cluster_network" {
  input = module.tenant.networks[local.network].id

  depends_on = [module.tenant]
}

# The bootstrap instance, in its own call: its user data carries the manifests, hence the
# addresses of the entries. In the call that creates the network, every router interface would
# depend on these addresses, and a change of an entry's plane would remove the interface before
# the floating IP that uses it, which Neutron refuses.
module "bootstrap" {
  source = "git::https://github.com/CyprisTech/terraform-openstack-tenant.git?ref=v0.1.5"

  tenant = {
    existing = {
      networks = merge({
        # Only the id comes from the relay: the shape stays known at plan (the module keys its
        # lookups on it).
        (local.network) = { id = terraform_data.cluster_network.output, subnets = { main = { name = local.subnet } } }
        },
        # The network of the bootstrap instance's floating IP: the internal services plane, or
        # the administration network.
        # By name too: the floating IP pool is the network's name, read by a lookup that waits.
        { for k in(local.admin_on_internal ? ["internal"] : []) : k => { name = module.planes.network_name.internal } },
        {
          for k in(local.admin_on_internal ? [] : ["admin"]) : k => {
            name = var.admin_network.network, subnets = { main = { name = var.admin_network.subnet } }
          }
      })
    }

    security_groups = {
      (local.instance) = {
        description = "Bootstrap instance: SSH from the administration sources"
        rules       = module.admission.rules
      }
    }

    instances = {
      for name in(var.bootstrap ? [local.instance] : []) : name => {
        az        = var.az
        flavor    = var.flavor
        image     = var.image
        boot      = var.boot_volume_size == null ? { source = "image" } : { source = "volume", size = var.boot_volume_size }
        user_data = module.cloudinit[0].rendered
        labels    = ["bootstrap"]
        ports = {
          main = {
            network         = local.network
            subnet          = "main"
            security_groups = [local.instance]
            floating_ip     = { pool = local.admin_on_internal ? "internal" : "admin" }
          }
        }
      }
    }
  }

}

moved {
  from = module.platform
  to   = module.tenant
}

# Demonstration mode: a warning at every plan and apply, without failing (ADR-0008).
check "certificates" {
  assert {
    condition     = var.certificates != null
    error_message = "certificates not set: self-signed certificate, for evaluation only (ADR-0008)."
  }
}
