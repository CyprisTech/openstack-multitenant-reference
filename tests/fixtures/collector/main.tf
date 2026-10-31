# Test collector for the isolation test: a small instance standing for the monitoring
# collector, a shared service of the monitoring plane. The tenants admit it by the addresses
# of the collector_cidrs output, given to the tenant stacks as monitoring.collector_cidrs:
# its router's gateway address on an operator plane (source NAT), its own range on an
# interface plane. It is administered through a floating IP on an administration network,
# whose router is its default gateway.

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
variable "site" { type = string }
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
variable "plane_attachment" {
  description = "The service's entry of the attachments output of stack shared/planes (role shared on monitoring)."
  type = map(object({
    mode         = string
    nat          = bool
    cidr         = string
    network_id   = string
    network_name = string
    subnet_id    = string
    routes       = optional(list(object({ destination = string, next_hop = string })), [])
  }))
}
variable "cidr" {
  description = "Range of the collector's network; on an interface plane, the attachment's cidr in shared/planes."
  type        = string
  default     = "10.34.0.0/28"
}
variable "admin_network" { type = object({ network = string, subnet = string }) }
variable "ssh_cidrs" { type = list(string) }
variable "ssh_keys" { type = list(string) }

locals {
  name = "${var.site}-collector"
}

module "planes" {
  source = "../../../modules/plane-attachment"

  planes     = ["monitoring"]
  attachment = var.plane_attachment
}

module "cloudinit" {
  source = "git::https://github.com/CyprisTech/terraform-openstack-tenant.git//modules/cloudinit?ref=v0.1.3"

  hostname       = local.name
  package_update = false
  users          = { debug = { ssh_authorized_keys = var.ssh_keys, sudo = true } }
}

module "collector" {
  source = "git::https://github.com/CyprisTech/terraform-openstack-tenant.git?ref=84c898b5d5036296a7cd3496a54e0721ccbc4936"

  tenant = {
    existing = {
      networks = merge({
        admin = { name = var.admin_network.network, subnets = { main = { name = var.admin_network.subnet } } }
      }, module.planes.networks)
    }
    networks = {
      (local.name) = {
        mtu     = var.network_mtu
        subnets = { main = { cidr = var.cidr } }
        routers = merge({
          admin = { external_network = "admin", internal_subnet = "main", default_gateway = true }
        }, module.planes.routers)
      }
    }
    security_groups = {
      (local.name) = {
        rules = { for i, c in var.ssh_cidrs : "ssh-${i}" => { direction = "ingress", protocol = "tcp", port_min = 22, port_max = 22, remote_ip_prefix = c } }
      }
    }
    instances = {
      (local.name) = {
        az        = var.az, flavor = var.flavor, image = var.image
        boot      = var.boot_volume_size == null ? { source = "image" } : { source = "volume", size = var.boot_volume_size }
        user_data = module.cloudinit.rendered
        ports     = { main = { network = local.name, subnet = "main", security_groups = [local.name], floating_ip = { pool = "admin" } } }
      }
    }
  }
}

data "openstack_networking_router_v2" "monitoring" {
  count     = module.planes.nat.monitoring ? 1 : 0
  router_id = module.collector.networks[local.name].routers["monitoring"].id
}

output "address" {
  description = "Floating IP of the collector on the administration network (SSH)."
  value       = module.collector.instances[local.name].ports["main"].floating_ip
}

output "collector_cidrs" {
  description = "Source addresses of the collector as seen by the tenants: its router's gateway address on an operator plane, its range on an interface plane."
  value = module.planes.nat.monitoring ? [
    for ip in data.openstack_networking_router_v2.monitoring[0].external_fixed_ip : "${ip.ip_address}/32"
  ] : [var.cidr]
}
