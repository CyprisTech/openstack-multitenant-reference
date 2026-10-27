# Test collector for the reachability matrix: a small instance standing for the monitoring
# collector. It reaches the monitoring plane through its own router (source NAT), so the
# tenants see a single, known source address: the router's gateway address on the plane,
# given to the tenant stacks as monitoring.collector_cidrs. It is administered through a
# floating IP on an administration network, whose router is its default gateway.

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
variable "monitoring_plane" { type = object({ network = string, subnet = string, cidr = string }) }
variable "admin_network" { type = object({ network = string, subnet = string }) }
variable "ssh_cidrs" { type = list(string) }
variable "ssh_keys" { type = list(string) }

locals {
  name = "${var.site}-collector"
}

module "cloudinit" {
  source = "git::https://github.com/CyprisTech/terraform-openstack-tenant.git//modules/cloudinit?ref=fa88febb8a2676282d9995ca36396be353e667df"

  hostname       = local.name
  package_update = false
  users          = { debug = { ssh_authorized_keys = var.ssh_keys, sudo = true } }
}

module "collector" {
  source = "git::https://github.com/CyprisTech/terraform-openstack-tenant.git?ref=fa88febb8a2676282d9995ca36396be353e667df"

  tenant = {
    existing = {
      networks = {
        admin      = { name = var.admin_network.network, subnets = { main = { name = var.admin_network.subnet } } }
        monitoring = { name = var.monitoring_plane.network, subnets = { main = { name = var.monitoring_plane.subnet } } }
      }
    }
    networks = {
      (local.name) = {
        mtu     = var.network_mtu
        subnets = { main = { cidr = "10.34.0.0/28" } }
        routers = {
          admin      = { external_network = "admin", internal_subnet = "main", default_gateway = true }
          monitoring = { external_network = "monitoring", internal_subnet = "main", advertise_routes = [var.monitoring_plane.cidr] }
        }
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
  router_id = module.collector.networks[local.name].routers["monitoring"].id
}

output "address" {
  description = "Floating IP of the collector on the administration network (SSH)."
  value       = module.collector.instances[local.name].ports["main"].floating_ip
}

output "collector_cidrs" {
  description = "Source addresses of the collector as seen on the monitoring plane."
  value       = [for ip in data.openstack_networking_router_v2.monitoring.external_fixed_ip : "${ip.ip_address}/32"]
}
