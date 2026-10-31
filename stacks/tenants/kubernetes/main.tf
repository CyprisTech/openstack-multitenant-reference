# Layer 30, tenant "platform": a Kubernetes cluster created by Cluster API with the OpenStack
# provider (ADR-0002). Terraform prepares the infrastructure of the project (D1): the cluster
# network with its routers to the planes, the server groups of the machines and the bootstrap
# instance. The cluster itself is described by the manifests of manifests/, rendered here and
# written on the bootstrap instance, where scripts/create-cluster.sh applies them.
#
# Terraform never handles the OpenStack credentials of the cluster: the operator copies a
# clouds.yaml to the bootstrap instance (see README.md), so they stay out of the state and of
# the instance metadata.

locals {
  prefix   = "${var.site}-platform"
  network  = local.prefix
  subnet   = "${local.prefix}-main"
  router   = local.admin_is_intranet ? "${local.prefix}-intranet" : "${local.prefix}-admin"
  instance = "${local.prefix}-bootstrap"

  admin_is_intranet = var.admin_network == null
  admin_network     = local.admin_is_intranet ? { network = module.planes.network_name.intranet } : { network = var.admin_network.network }

  expose_prometheus = length(var.monitoring.collector_cidrs) > 0
  prometheus_record = local.expose_prometheus && var.monitoring.dns_zone != null

  # Addresses of the cluster Services (ADR-0002, D5): a floating IP of the plane in gateway
  # mode; a fixed address of the cluster network in interface mode.
  ingress_internal    = !module.planes.nat.svc_public
  prometheus_internal = !module.planes.nat.monitoring
  ingress_address     = local.ingress_internal ? cidrhost(var.cluster_cidr, var.service_addresses.ingress) : openstack_networking_floatingip_v2.ingress[0].address
  prometheus_address = !local.expose_prometheus ? "" : (
    local.prometheus_internal ? cidrhost(var.cluster_cidr, var.service_addresses.prometheus) : openstack_networking_floatingip_v2.prometheus[0].address
  )
}

# How the cluster network joins the planes (ADR-0003, D2).
module "planes" {
  source = "../../../modules/plane-attachment"

  planes     = ["svc_public", "monitoring", "intranet"]
  attachment = var.plane_attachment
}

# Who may reach the bootstrap instance.
module "admission" {
  source = "../../../modules/admission"

  allow = {
    ssh = { ports = [22], sources = var.admin.sources }
  }
}

# The intranet carries the administration role only when it is an operator plane: the API and
# the bootstrap instance need floating IPs.
resource "terraform_data" "checks" {
  lifecycle {
    precondition {
      condition     = !local.admin_is_intranet || module.planes.nat.intranet
      error_message = "The intranet plane gives no floating IPs (nat = false): set admin_network, an external network for the API and bootstrap floating IPs."
    }
  }
}

# Addresses of the cluster Services (ADR-0002, D5), created here rather than by the cloud
# controller manager: they are known before the cluster exists, they are outputs of the stack
# (the routes of the entry point and the monitoring record come from them, ADR-0001, D9), and
# they survive the Services. The Services request them (spec.loadBalancerIP) and the cloud
# controller manager never deletes them (keep-floatingip).
resource "openstack_networking_floatingip_v2" "ingress" {
  count = local.ingress_internal ? 0 : 1

  pool        = module.planes.network_name.svc_public
  description = "${local.prefix} ingress"
}

resource "openstack_networking_floatingip_v2" "prometheus" {
  count = local.expose_prometheus && !local.prometheus_internal ? 1 : 0

  pool        = module.planes.network_name.monitoring
  description = "${local.prefix} prometheus"
}

module "platform" {
  source = "git::https://github.com/CyprisTech/terraform-openstack-tenant.git?ref=84c898b5d5036296a7cd3496a54e0721ccbc4936"

  tenant = {
    existing = {
      networks = merge({
        egress = { name = var.egress_network.network, subnets = { main = { name = var.egress_network.subnet } } }
        }, module.planes.networks, {
        for k in(local.admin_is_intranet ? [] : ["admin"]) : k => {
          name = var.admin_network.network, subnets = { main = { name = var.admin_network.subnet } }
        }
      })
      dns_zones = local.prometheus_record ? { monitoring = { name = var.monitoring.dns_zone } } : {}
    }

    # The collector discovers the federation endpoint by DNS, like every other target (ADR-0001, D2).
    dns = {
      records = local.prometheus_record ? {
        prometheus = {
          zone    = "monitoring", name = "${local.prefix}-prometheus", type = "A"
          records = [local.prometheus_address]
        }
      } : {}
    }

    networks = {
      (local.network) = {
        mtu = var.network_mtu
        subnets = {
          main = {
            cidr            = var.cluster_cidr
            dns_nameservers = var.dns_nameservers
            # The first addresses are kept for the load balancers of the Services on interface planes.
            allocation_pools = local.ingress_internal || local.prometheus_internal ? [{
              start = cidrhost(var.cluster_cidr, var.service_addresses.reserved_hosts)
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
          for k in(local.admin_is_intranet ? [] : ["admin"]) : k => {
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
            floating_ip     = { pool = local.admin_is_intranet ? "intranet" : "admin" }
          }
        }
      }
    }
  }
}
