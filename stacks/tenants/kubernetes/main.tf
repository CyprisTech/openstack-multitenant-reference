# Kubernetes tenant: a Kubernetes cluster created by Cluster API with the OpenStack
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
  router   = local.admin_on_internal ? "${local.prefix}-internal" : "${local.prefix}-admin"
  instance = "${local.prefix}-bootstrap"

  admin_on_internal = var.admin_network == null
  admin_network     = local.admin_on_internal ? { network = module.planes.network_name.internal } : { network = var.admin_network.network }

  # The service address of the tenant (ADR-0006, D1): its ingress load balancer, at a floating
  # IP of publication when the plane translates addresses, at a fixed address of the cluster
  # network otherwise.
  ingress_internal = !module.planes.nat.publication
  ingress_address  = local.ingress_internal ? cidrhost(var.cluster_cidr, var.service_addresses.ingress) : openstack_networking_floatingip_v2.ingress[0].address
}

# How the cluster network joins the planes (ADR-0004).
module "planes" {
  source = "../../../modules/plane-attachment"

  planes     = ["publication", "observability", "internal"]
  attachment = var.plane_attachment
}

# Who may reach the bootstrap instance.
module "admission" {
  source = "../../../modules/admission"

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

# Address of the ingress Service, created here rather than by the cloud controller manager: it
# is known before the cluster exists, it is an output of the stack (the route of the entry point
# comes from it), and it survives the Service. The Services request them (spec.loadBalancerIP) and the cloud
# controller manager never deletes them (keep-floatingip).
resource "openstack_networking_floatingip_v2" "ingress" {
  count = local.ingress_internal ? 0 : 1

  pool        = module.planes.network_name.publication
  description = "${local.prefix} ingress"
}

module "platform" {
  source = "git::https://github.com/CyprisTech/terraform-openstack-tenant.git?ref=v0.1.4"

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
            # The first addresses are kept for the ingress load balancer on a plane without NAT.
            allocation_pools = local.ingress_internal ? [{
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

# Demonstration mode: a warning at every plan and apply, without failing (ADR-0008).
check "certificates" {
  assert {
    condition     = var.certificates != null
    error_message = "certificates not set: self-signed certificate, for evaluation only (ADR-0008)."
  }
}
