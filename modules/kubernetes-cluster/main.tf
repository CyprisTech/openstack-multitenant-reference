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
  admin_network     = local.admin_on_internal ? { network = module.planes.network_name.internal } : { network = var.admin_network.network }

  # The entries of the cluster (ADR-0006, D1): each one at a floating IP of its plane when the
  # plane translates addresses, at a fixed address of the cluster network otherwise.
  ingresses = { for k, i in var.ingresses : k => merge(i, {
    namespace  = coalesce(i.namespace, "traefik-${k}")
    tls_secret = coalesce(i.tls_secret, "${k}-tls")
  }) }
  entries = merge(
    { for k, i in var.ingresses : k => { plane = i.plane, host = i.host } },
    { for k, s in var.services : "service-${k}" => { plane = s.plane, host = s.host } },
  )
  entry_nat     = { for k, e in local.entries : k => module.planes.nat[e.plane] }
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
      condition     = !local.admin_on_internal || module.planes.nat.internal
      error_message = "The internal services plane gives no floating IPs (nat = false): set admin_network, an external network for the API and bootstrap floating IPs."
    }
  }
}

# Addresses of the entries on planes with NAT, created here rather than by the cloud controller
# manager: they are known before the cluster exists, they are outputs (the routes of the entry
# point and the consumers' admissions come from them), and they survive the Services. The
# Services request them (spec.loadBalancerIP) and the cloud controller manager never deletes
# them (keep-floatingip).
resource "openstack_networking_floatingip_v2" "entry" {
  for_each = { for k, e in local.entries : k => e if local.entry_nat[k] }

  pool        = module.planes.network_name[each.value.plane]
  description = "${local.prefix} ${each.key}"
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

    security_groups = {
      (local.instance) = {
        description = "Bootstrap instance: SSH from the administration sources"
        rules       = module.admission.rules
      }
    }

    # Read by the machine templates (ADR-0002, D2). Soft anti-affinity: the cluster still
    # starts when the cloud has fewer hosts than machines.
    server_groups = {
      "${local.prefix}-control-plane" = { policy = "soft-anti-affinity" }
      "${local.prefix}-workers"       = { policy = "soft-anti-affinity" }
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
