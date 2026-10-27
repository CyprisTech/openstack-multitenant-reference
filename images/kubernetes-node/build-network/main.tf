# Build network of the Kubernetes node image (ADR-0002, D1). image-builder (Packer, OpenStack
# builder) starts a temporary instance on this network, provisions it over SSH, then turns it
# into a private image of the project.
#
# The network has its own state and lifecycle: the image outlives the cluster, and rebuilding
# it does not touch the platform stack. Two routers:
# - egress, the default route: the build downloads packages and container images;
# - admin, which carries the floating IP Packer connects to, on the administration network.
#   Only the administration sources are routed through it (advertised by DHCP), so that the
#   replies to Packer leave through the router that received the connection.

locals {
  prefix = "${var.site}-node-image"
}

module "build" {
  source = "git::https://github.com/CyprisTech/terraform-openstack-tenant.git?ref=v0.1.2"

  tenant = {
    existing = {
      networks = {
        egress = { name = var.egress_network.network, subnets = { main = { name = var.egress_network.subnet } } }
        admin  = { name = var.admin_network.network, subnets = { main = { name = var.admin_network.subnet } } }
      }
    }

    networks = {
      (local.prefix) = {
        mtu = var.network_mtu
        subnets = {
          main = { cidr = var.build_cidr, dns_nameservers = var.dns_nameservers }
        }
        routers = {
          egress = { external_network = "egress", internal_subnet = "main", default_gateway = true }
          admin = {
            external_network = "admin", internal_subnet = "main",
            advertise_routes = var.ssh_cidrs
          }
        }
      }
    }

    security_groups = {
      (local.prefix) = {
        description = "Node image build instance: SSH from the administration sources"
        rules = {
          for i, cidr in var.ssh_cidrs : "ssh-${i}" => {
            direction = "ingress", protocol = "tcp", port_min = 22, port_max = 22, remote_ip_prefix = cidr
          }
        }
      }
    }
  }
}
