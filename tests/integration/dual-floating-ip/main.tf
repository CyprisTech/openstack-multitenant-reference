# Integration test: one port with two floating IPs from two different external networks
# (svc_public through the module, monitoring added beside it), each external network reached
# through its own router. Checks that both addresses answer at the same time, and that the
# instance keeps its Internet access.
#
#   target: network A, floating IP on svc_public (module) + floating IP on monitoring (here)
#   client: network B, floating IP on monitoring; reaches the target through svc_public

terraform {
  required_version = ">= 1.9"
  required_providers {
    openstack = { source = "terraform-provider-openstack/openstack", version = "~> 3.2" }
  }
}

provider "openstack" {
  cloud = var.cloud
}

variable "cloud" { type = string }
variable "az" { type = string }
variable "image" { type = string }
variable "flavor" { type = string }
variable "boot_volume_size" {
  type    = number
  default = null
}
variable "network_mtu" {
  type    = number
  default = null
}
variable "dns_nameservers" { type = list(string) }
variable "egress_network" { type = object({ network = string, subnet = string }) }
variable "svc_public" { type = object({ network = string, subnet = string, cidr = string }) }
variable "monitoring" { type = object({ network = string, subnet = string, cidr = string }) }
variable "ssh_keys" { type = list(string) }
variable "admin_network" { type = object({ network = string, subnet = string, cidr = string }) }

locals {
  boot = var.boot_volume_size == null ? { source = "image" } : { source = "volume", size = var.boot_volume_size }
  routers = {
    egress     = { external_network = "egress", internal_subnet = "main", default_gateway = true }
    svc-public = { external_network = "svc_public", internal_subnet = "main", advertise_routes = [var.svc_public.cidr] }
    monitoring = { external_network = "monitoring", internal_subnet = "main", advertise_routes = [var.monitoring.cidr] }
  }
}

module "cloudinit" {
  source   = "git::https://github.com/CyprisTech/terraform-openstack-tenant.git//modules/cloudinit?ref=v0.1.1"
  for_each = toset(["dfip-target", "dfip-client"])

  hostname       = each.key
  users          = { debug = { ssh_authorized_keys = var.ssh_keys, sudo = true } }
  package_update = false
}

module "test" {
  source = "git::https://github.com/CyprisTech/terraform-openstack-tenant.git?ref=v0.1.1"

  tenant = {
    existing = {
      networks = {
        egress     = { name = var.egress_network.network, subnets = { main = { name = var.egress_network.subnet } } }
        svc_public = { name = var.svc_public.network, subnets = { main = { name = var.svc_public.subnet } } }
        monitoring = { name = var.monitoring.network, subnets = { main = { name = var.monitoring.subnet } } }
        admin      = { name = var.admin_network.network, subnets = { main = { name = var.admin_network.subnet } } }
      }
    }
    networks = {
      dfip-a = { mtu = var.network_mtu, subnets = { main = { cidr = "10.23.0.0/24", dns_nameservers = var.dns_nameservers } }, routers = local.routers }
      dfip-b = {
        mtu     = var.network_mtu
        subnets = { main = { cidr = "10.24.0.0/24", dns_nameservers = var.dns_nameservers } }
        # The client is administered through the admin network: its router is the default
        # gateway, so that replies to administrators return the way they came.
        routers = {
          admin      = { external_network = "admin", internal_subnet = "main", default_gateway = true }
          svc-public = { external_network = "svc_public", internal_subnet = "main", advertise_routes = [var.svc_public.cidr] }
          monitoring = { external_network = "monitoring", internal_subnet = "main", advertise_routes = [var.monitoring.cidr] }
        }
      }
    }
    security_groups = {
      dfip-ssh = {
        rules = {
          from-monitoring = { direction = "ingress", protocol = "tcp", port_min = 22, port_max = 22, remote_ip_prefix = var.monitoring.cidr }
          from-admin      = { direction = "ingress", protocol = "tcp", port_min = 22, port_max = 22, remote_ip_prefix = var.admin_network.cidr }
          from-svc-public = { direction = "ingress", protocol = "tcp", port_min = 22, port_max = 22, remote_ip_prefix = var.svc_public.cidr }
        }
      }
    }
    instances = {
      dfip-target = {
        az        = var.az, flavor = var.flavor, image = var.image, boot = local.boot
        user_data = module.cloudinit["dfip-target"].rendered
        ports     = { main = { network = "dfip-a", subnet = "main", security_groups = ["dfip-ssh"], floating_ip = { pool = "svc_public" } } }
      }
      dfip-client = {
        az        = var.az, flavor = var.flavor, image = var.image, boot = local.boot
        user_data = module.cloudinit["dfip-client"].rendered
        ports     = { main = { network = "dfip-b", subnet = "main", security_groups = ["dfip-ssh"], floating_ip = { pool = "admin" } } }
      }
    }
  }
}

# Second floating IP of the target port, on the monitoring network.
data "openstack_networking_network_v2" "monitoring" {
  name = var.monitoring.network
}

resource "openstack_networking_floatingip_v2" "target_monitoring" {
  pool = data.openstack_networking_network_v2.monitoring.name
}

# The composite output does not expose port IDs; the port is found by its name.
data "openstack_networking_port_v2" "target" {
  name       = "dfip-target-main"
  depends_on = [module.test]
}

resource "openstack_networking_floatingip_associate_v2" "target_monitoring" {
  floating_ip = openstack_networking_floatingip_v2.target_monitoring.address
  port_id     = data.openstack_networking_port_v2.target.id
}

output "target" {
  value = {
    private    = module.test.instances["dfip-target"].ports["main"].ip
    svc_public = module.test.instances["dfip-target"].ports["main"].floating_ip
    monitoring = openstack_networking_floatingip_v2.target_monitoring.address
  }
}

output "client" {
  value = {
    private    = module.test.instances["dfip-client"].ports["main"].ip
    monitoring = module.test.instances["dfip-client"].ports["main"].floating_ip
  }
}
