# Tenant "isolated": a workload with no public exposure and no path to the other tenants
# (ADR-0001, D5). Its network has a single router, to the monitoring plane: the collector
# reaches the instance through it, and it reaches nothing but the monitoring plane.
#
# The workload is a stand-in: a metrics endpoint served by the Python standard library,
# so that the instance needs no package and no Internet access.

locals {
  prefix   = "${var.site}-isolated"
  instance = "${local.prefix}-1"

  bastion_name = "${local.prefix}-bastion"

  # Sources of the metrics scrapes: the collector only.
  metrics_sources = coalesce(var.monitoring.collector_cidrs, [module.planes.cidr.monitoring])

  metrics_unit = <<-EOT
    [Unit]
    Description=Stand-in metrics endpoint
    After=network-online.target

    [Service]
    ExecStart=/usr/bin/python3 -m http.server ${var.monitoring.metrics_ports[0]} --directory /srv/metrics
    Restart=always
    DynamicUser=yes

    [Install]
    WantedBy=multi-user.target
  EOT
}

# How the stack joins the monitoring plane (ADR-0004). Its router is the default gateway:
# the tenant has no other way out.
module "planes" {
  source = "../../../modules/plane-attachment"

  planes          = ["monitoring"]
  attachment      = var.plane_attachment
  default_gateway = "monitoring"
  instances       = [local.instance]
  exposure = {
    primary = "monitoring"
    dns     = var.monitoring.dns_zone == null ? null : { plane = "monitoring", zone = "monitoring" }
  }
}

# Who may reach the instance.
module "admission" {
  source = "../../../modules/admission"

  allow = {
    metrics = { ports = var.monitoring.metrics_ports, sources = local.metrics_sources }
    ssh     = { ports = [22], sources = var.admin.ssh_cidrs }
  }
}

module "bastion" {
  source = "../../../modules/bastion"

  name          = local.bastion_name
  bastion       = var.bastion
  admin_network = "${local.prefix}-admin"
  default_cidr  = "10.33.0.0/28"
  network       = local.prefix
  port          = "isolated"
  users         = var.admin.users
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

  hostname       = local.instance
  package_update = false # no Internet access by design
  users = {
    for login, keys in var.admin.users : login => { ssh_authorized_keys = keys, sudo = true }
  }

  write_files = {
    "/srv/metrics/metrics" = {
      content = "# Stand-in metrics of the isolated workload\nisolated_up 1\n"
    }
    "/etc/systemd/system/metrics.service" = {
      content = local.metrics_unit
    }
  }
  runcmd = [
    "systemctl daemon-reload",
    "systemctl enable --now metrics.service",
  ]
}

module "isolated" {
  source = "git::https://github.com/CyprisTech/terraform-openstack-tenant.git?ref=84c898b5d5036296a7cd3496a54e0721ccbc4936"

  tenant = {
    existing = {
      dns_zones = var.monitoring.dns_zone == null ? {} : { monitoring = { name = var.monitoring.dns_zone } }
      networks  = merge(module.planes.networks, module.bastion.existing_networks)
    }

    networks = merge({
      (local.prefix) = {
        mtu     = var.network_mtu
        subnets = { main = { cidr = var.isolated_cidr, dns_nameservers = var.dns_nameservers } }
        # The only router, to the monitoring plane, also the default gateway.
        routers = module.planes.routers
      }
    }, module.bastion.networks)

    security_groups = merge({
      "${local.prefix}-workload" = {
        description = "Isolated workload: metrics from the collector only, SSH from the bastion"
        rules       = merge(module.admission.rules, module.bastion.ssh_rules)
      }
    }, module.bastion.security_groups)

    instances = merge({
      (local.instance) = {
        az        = var.az
        flavor    = var.flavor
        image     = var.image
        boot      = var.boot_volume_size == null ? { source = "image" } : { source = "volume", size = var.boot_volume_size }
        user_data = module.cloudinit.rendered
        labels    = ["isolated"]
        ports = {
          main = {
            network         = local.prefix
            subnet          = "main"
            security_groups = ["${local.prefix}-workload"]
            # Exposure to the monitoring collector (ADR-0001, D2): the only published address.
            floating_ip        = module.planes.ports[local.instance].floating_ip
            extra_floating_ips = module.planes.ports[local.instance].extra_floating_ips
            dns                = module.planes.ports[local.instance].dns
          }
        }
      }
    }, module.bastion.instances)
  }
}
