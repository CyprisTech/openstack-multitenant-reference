# Intranet demonstration service for the reachability matrix (ADR-0002, D7): a small instance
# published on the intranet plane with a floating IP, answering on port 8080. Only the
# platform tenant is admitted, by the address under which it reaches the intranet (the
# gateway address of its intranet router, read by name). The same floating IP carries SSH
# for the administration sources, since the test cloud uses the intranet as administration
# network.

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
variable "intranet" { type = object({ network = string, subnet = string }) }
variable "ssh_cidrs" { type = list(string) }
variable "ssh_keys" { type = list(string) }

locals {
  name = "${var.site}-intranet-service"
  # Sources admitted on the service port: the platform tenant only.
  service_sources = [for ip in data.openstack_networking_router_v2.platform_intranet.external_fixed_ip : "${ip.ip_address}/32"]
}

data "openstack_networking_router_v2" "platform_intranet" {
  name = "${var.site}-platform-intranet"
}

module "cloudinit" {
  source = "git::https://github.com/CyprisTech/terraform-openstack-tenant.git//modules/cloudinit?ref=v0.1.2"

  hostname       = local.name
  package_update = false
  users          = { debug = { ssh_authorized_keys = var.ssh_keys, sudo = true } }
  write_files = {
    "/srv/www/index.html" = { content = "intranet-service\n" }
    "/etc/systemd/system/intranet-service.service" = {
      content = <<-EOT
        [Unit]
        Description=Intranet demonstration service
        After=network-online.target

        [Service]
        ExecStart=/usr/bin/python3 -m http.server 8080 --directory /srv/www
        Restart=always
        DynamicUser=yes

        [Install]
        WantedBy=multi-user.target
      EOT
    }
  }
  runcmd = ["systemctl daemon-reload", "systemctl enable --now intranet-service.service"]
}

module "service" {
  source = "git::https://github.com/CyprisTech/terraform-openstack-tenant.git?ref=v0.1.2"

  tenant = {
    existing = {
      networks = {
        intranet = { name = var.intranet.network, subnets = { main = { name = var.intranet.subnet } } }
      }
    }
    networks = {
      (local.name) = {
        mtu     = var.network_mtu
        subnets = { main = { cidr = "10.35.0.0/28" } }
        routers = {
          intranet = { external_network = "intranet", internal_subnet = "main", default_gateway = true }
        }
      }
    }
    security_groups = {
      (local.name) = {
        rules = merge(
          { for i, c in var.ssh_cidrs : "ssh-${i}" => { direction = "ingress", protocol = "tcp", port_min = 22, port_max = 22, remote_ip_prefix = c } },
          { for i, c in local.service_sources : "service-${i}" => { direction = "ingress", protocol = "tcp", port_min = 8080, port_max = 8080, remote_ip_prefix = c } },
        )
      }
    }
    instances = {
      (local.name) = {
        az        = var.az, flavor = var.flavor, image = var.image
        boot      = var.boot_volume_size == null ? { source = "image" } : { source = "volume", size = var.boot_volume_size }
        user_data = module.cloudinit.rendered
        ports     = { main = { network = local.name, subnet = "main", security_groups = [local.name], floating_ip = { pool = "intranet" } } }
      }
    }
  }
}

output "address" {
  description = "Floating IP of the service on the intranet (port 8080; SSH from the administration sources)."
  value       = module.service.instances[local.name].ports["main"].floating_ip
}

output "service_sources" {
  description = "Sources admitted on port 8080."
  value       = local.service_sources
}
