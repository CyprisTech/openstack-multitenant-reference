# Test receiver: a small instance standing for the metrics receiver, a shared service of the
# monitoring plane (ADR-0007). Prometheus with its remote-write and OTLP receivers: the tenants
# push to the receiver_url output; nothing connects into the tenants. It is administered through
# a bastion, like the stacks, and gets packages and its image through egress_network.

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
variable "dns_nameservers" {
  type    = list(string)
  default = []
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
  description = "Range of the receiver's network; on an interface plane, the attachment's cidr in shared/planes."
  type        = string
  default     = "10.34.0.0/28"
}
variable "egress_network" {
  description = "External network giving the default route (package and image download)."
  type        = object({ network = string, subnet = string })
}
variable "bastion" {
  description = "Administration bastion: floating IP on external_network, SSH from ssh_cidrs."
  type = object({
    external_network = object({ network = string, subnet = string })
    ssh_cidrs        = list(string)
  })
}
variable "users" {
  description = "SSH users (login => public keys, sudo granted), on the bastion and the receiver."
  type        = map(list(string))
}
variable "prometheus_image" {
  description = "Prometheus image, pinned."
  type        = string
  default     = "docker.io/prom/prometheus:v3.15.1"
}

locals {
  name = "${var.site}-receiver"

  # Who may push: on a plane with NAT, the tenants' routers, seen at their gateway address on
  # the plane; on an interface plane, the ranges routed to the receiver.
  push_sources = module.planes.nat.monitoring ? [module.planes.cidr.monitoring] : [
    for r in var.plane_attachment.monitoring.routes : r.destination
  ]

  config = yamlencode({
    global = { scrape_interval = "30s" }
    # OTLP resources: their site and tenant become labels, like the external labels of the agents.
    otlp           = { promote_resource_attributes = ["site", "tenant"] }
    scrape_configs = [{ job_name = "receiver", static_configs = [{ targets = ["localhost:9090"] }] }]
  })

  unit = <<-EOT
    [Unit]
    Description=Prometheus (test receiver)
    Wants=network-online.target
    After=network-online.target

    [Service]
    ExecStartPre=-/usr/bin/podman rm --force prometheus
    ExecStart=/usr/bin/podman run --rm --name prometheus --network host \
      --volume /etc/prometheus:/etc/prometheus:ro \
      ${var.prometheus_image} --config.file=/etc/prometheus/prometheus.yml \
      --web.enable-remote-write-receiver --web.enable-otlp-receiver
    ExecStop=/usr/bin/podman stop --time 10 prometheus
    Restart=always
    RestartSec=5

    [Install]
    WantedBy=multi-user.target
  EOT
}

module "planes" {
  source = "../../../modules/plane-attachment"

  planes     = ["monitoring"]
  attachment = var.plane_attachment
  instances  = [local.name]
  exposure   = { primary = "monitoring" }
}

module "admission" {
  source = "../../../modules/admission"

  allow = {
    push = { ports = [9090], sources = local.push_sources }
  }
}

module "bastion" {
  source = "../../../modules/bastion"

  name          = "${local.name}-bastion"
  bastion       = var.bastion
  admin_network = "${local.name}-admin"
  default_cidr  = "10.36.0.0/28"
  network       = local.name
  port          = "receiver"
  users         = var.users
  instance = {
    az     = var.az
    image  = var.image
    flavor = var.flavor
    boot   = var.boot_volume_size == null ? { source = "image" } : { source = "volume", size = var.boot_volume_size }
  }
  mtu             = var.network_mtu
  dns_nameservers = var.dns_nameservers
}

module "cloudinit" {
  source = "git::https://github.com/CyprisTech/terraform-openstack-tenant.git//modules/cloudinit?ref=v0.1.3"

  hostname     = local.name
  users        = { for login, keys in var.users : login => { ssh_authorized_keys = keys, sudo = true } }
  packages     = ["podman"]
  extra_config = { apt = { conf = "Acquire::Retries \"10\";\n" } }
  write_files = {
    "/etc/prometheus/prometheus.yml"         = { content = local.config }
    "/etc/systemd/system/prometheus.service" = { content = local.unit }
  }
  runcmd = ["systemctl daemon-reload", "systemctl enable --now prometheus.service"]
}

module "receiver" {
  source = "git::https://github.com/CyprisTech/terraform-openstack-tenant.git?ref=84c898b5d5036296a7cd3496a54e0721ccbc4936"

  tenant = {
    existing = {
      networks = merge({
        egress = { name = var.egress_network.network, subnets = { main = { name = var.egress_network.subnet } } }
      }, module.planes.networks, module.bastion.existing_networks)
    }
    networks = merge({
      (local.name) = {
        mtu     = var.network_mtu
        subnets = { main = { cidr = var.cidr, dns_nameservers = var.dns_nameservers } }
        routers = merge({
          egress = { external_network = "egress", internal_subnet = "main", default_gateway = true }
        }, module.planes.routers)
      }
    }, module.bastion.networks)
    security_groups = merge({
      (local.name) = {
        description = "Test receiver: pushes from the monitoring plane, SSH from the bastion"
        rules       = merge(module.admission.rules, module.bastion.ssh_rules)
      }
    }, module.bastion.security_groups)
    instances = merge({
      (local.name) = {
        az        = var.az, flavor = var.flavor, image = var.image
        boot      = var.boot_volume_size == null ? { source = "image" } : { source = "volume", size = var.boot_volume_size }
        user_data = module.cloudinit.rendered
        ports = {
          main = {
            network = local.name, subnet = "main", security_groups = [local.name]
            # Its address on the monitoring plane: a floating IP of the plane when it translates
            # addresses, its own address otherwise.
            floating_ip = module.planes.ports[local.name].floating_ip
          }
        }
      }
    }, module.bastion.instances)
  }
}

locals {
  address = module.planes.nat.monitoring ? module.receiver.instances[local.name].ports["main"].floating_ip : module.receiver.instances[local.name].ports["main"].ip
}

output "receiver_url" {
  description = "Base URL of the receiver, for the monitoring.receiver input of the stacks."
  value       = "http://${local.address}:9090"
}

output "address" {
  description = "Address of the receiver on its network, reached through the bastion (SSH)."
  value       = module.receiver.instances[local.name].ports["main"].ip
}

output "bastion" {
  description = "Floating IP of the bastion on the administration network."
  value       = module.receiver.instances["${local.name}-bastion"].ports["admin"].floating_ip
}
