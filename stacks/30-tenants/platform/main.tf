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
  admin_network     = local.admin_is_intranet ? var.planes.intranet : var.admin_network

  ssh_rules = {
    for i, cidr in var.admin.sources : "ssh-${i}" => {
      direction = "ingress", protocol = "tcp", port_min = 22, port_max = 22, remote_ip_prefix = cidr
    }
  }

  # Addresses of the entry point on svc_public, read from its router by name (ADR-0001, D1 and
  # D9): only they may reach the ingress, and only they are trusted to send a PROXY header.
  edge_sources = [for ip in data.openstack_networking_router_v2.edge_svc_public.external_fixed_ip : "${ip.ip_address}/32"]
}

data "openstack_networking_router_v2" "edge_svc_public" {
  name = "${var.site}-edge-svc-public"
}

module "platform" {
  source = "git::https://github.com/CyprisTech/terraform-openstack-tenant.git?ref=v0.1.2"

  tenant = {
    existing = {
      networks = merge({
        egress     = { name = var.egress_network.network, subnets = { main = { name = var.egress_network.subnet } } }
        svc_public = { name = var.planes.svc_public.network, subnets = { main = { name = var.planes.svc_public.subnet } } }
        monitoring = { name = var.planes.monitoring.network, subnets = { main = { name = var.planes.monitoring.subnet } } }
        intranet   = { name = var.planes.intranet.network, subnets = { main = { name = var.planes.intranet.subnet } } }
        }, {
        for k in(local.admin_is_intranet ? [] : ["admin"]) : k => {
          name = var.admin_network.network, subnets = { main = { name = var.admin_network.subnet } }
        }
      })
    }

    networks = {
      (local.network) = {
        mtu = var.network_mtu
        subnets = {
          main = { cidr = var.cluster_cidr, dns_nameservers = var.dns_nameservers }
        }
        # One router per plane; only the planes' ranges are routed through them (DHCP routes).
        # The router to the administration network also carries the floating IPs of the API
        # and of the bootstrap instance; CAPO adds its external address to the sources admitted
        # by the API load balancer, since the nodes reach the API through it.
        routers = merge({
          egress = { external_network = "egress", internal_subnet = "main", default_gateway = true }
          svc-public = {
            external_network = "svc_public", internal_subnet = "main",
            advertise_routes = [var.planes.svc_public.cidr]
          }
          monitoring = {
            external_network = "monitoring", internal_subnet = "main",
            advertise_routes = [var.planes.monitoring.cidr]
          }
          intranet = {
            external_network = "intranet", internal_subnet = "main",
            advertise_routes = [var.planes.intranet.cidr]
          }
          }, {
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
        rules       = local.ssh_rules
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
