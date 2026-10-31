# Intranet demonstration service for the isolation test (ADR-0002, D7): a small instance, a
# shared service of the intranet plane, answering on port 8080. Only the sources given in
# allowed_sources are admitted: the Kubernetes tenant's intranet address (its router's
# gateway address on an operator plane, its range on an interface plane). On an operator
# plane the service has a floating IP of the plane, which also carries SSH for the
# administration sources (the test cloud uses the intranet as administration network).

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
  description = "The service's entry of the attachments output of stack shared/planes (role shared on intranet)."
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
  description = "Range of the service's network; on an interface plane, the attachment's cidr in shared/planes."
  type        = string
  default     = "10.35.0.0/28"
}
variable "allowed_sources" {
  description = "Sources admitted on port 8080: output intranet_sources of the Kubernetes tenant."
  type        = list(string)
}
variable "ssh_cidrs" { type = list(string) }
variable "ssh_keys" { type = list(string) }

locals {
  name = "${var.site}-intranet-service"
}

module "planes" {
  source = "../../../modules/plane-attachment"

  planes          = ["intranet"]
  attachment      = var.plane_attachment
  default_gateway = "intranet"
  instances       = [local.name]
  exposure        = { primary = "intranet" }
}

module "admission" {
  source = "../../../modules/admission"

  allow = {
    service = { ports = [8080], sources = var.allowed_sources }
    ssh     = { ports = [22], sources = var.ssh_cidrs }
  }
}

module "cloudinit" {
  source = "git::https://github.com/CyprisTech/terraform-openstack-tenant.git//modules/cloudinit?ref=v0.1.3"

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
  source = "git::https://github.com/CyprisTech/terraform-openstack-tenant.git?ref=84c898b5d5036296a7cd3496a54e0721ccbc4936"

  tenant = {
    existing = {
      networks = module.planes.networks
    }
    networks = {
      (local.name) = {
        mtu     = var.network_mtu
        subnets = { main = { cidr = var.cidr } }
        routers = module.planes.routers
      }
    }
    security_groups = {
      (local.name) = {
        rules = module.admission.rules
      }
    }
    instances = {
      (local.name) = {
        az        = var.az, flavor = var.flavor, image = var.image
        boot      = var.boot_volume_size == null ? { source = "image" } : { source = "volume", size = var.boot_volume_size }
        user_data = module.cloudinit.rendered
        ports = {
          main = {
            network     = local.name, subnet = "main", security_groups = [local.name]
            floating_ip = module.planes.ports[local.name].floating_ip
          }
        }
      }
    }
  }
}

output "address" {
  description = "Address of the service on the intranet (port 8080): its floating IP on an operator plane (which also carries SSH), its own address on an interface plane."
  value       = module.planes.nat.intranet ? module.service.instances[local.name].ports["main"].floating_ip : module.service.instances[local.name].ports["main"].ip
}

output "service_sources" {
  description = "Sources admitted on port 8080."
  value       = var.allowed_sources
}
