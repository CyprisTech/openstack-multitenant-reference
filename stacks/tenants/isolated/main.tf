# Tenant "isolated": a workload with no public exposure and no path to the other tenants
# (ADR-0003, D3). Its network has a single router, to the observability plane: the workload pushes
# its metrics to the receiver through it (ADR-0007), and reaches nothing else.
#
# The workload is a stand-in with no package and no Internet access: it pushes one metric in
# OTLP (JSON over HTTP, Python standard library), which the receiver accepts as well as remote
# write.

locals {
  prefix   = "${var.site}-isolated"
  instance = "${local.prefix}-1"

  bastion_name = "${local.prefix}-bastion"

  # Boot disk of the instances: the image's ephemeral disk, or a volume of the given size.
  boot = var.boot_volume_size == null ? { source = "image" } : { source = "volume", size = var.boot_volume_size }
}

# How the stack joins the observability plane (ADR-0004). Its router is the default gateway:
# the tenant has no other way out.
module "planes" {
  source = "../../../modules/plane-attachment"

  planes          = ["observability"]
  attachment      = var.plane_attachment
  default_gateway = "observability"
}

module "admission" {
  source = "../../../modules/admission"

  allow = {
    ssh = { ports = [22], sources = var.admin.ssh_cidrs }
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
    boot   = local.boot
  }
  mtu             = var.network_mtu
  dns_nameservers = var.dns_nameservers
}

module "cloudinit" {
  source = "git::https://github.com/CyprisTech/terraform-openstack-tenant.git//modules/cloudinit?ref=v0.1.5"

  hostname       = local.instance
  package_update = false # no Internet access by design
  users = {
    for login, keys in var.admin.users : login => { ssh_authorized_keys = keys, sudo = true }
  }

  write_files = var.monitoring.receiver == null ? {} : {
    "/usr/local/bin/push-metrics" = {
      content     = templatefile("${path.module}/files/push-metrics.py.tftpl", { instance = local.instance, site = var.site })
      permissions = "0755"
    }
    "/etc/systemd/system/push-metrics.service" = {
      content = templatefile("${path.module}/files/push-metrics.service.tftpl", { receiver = coalesce(var.monitoring.receiver, "none") })
    }
  }
  runcmd = var.monitoring.receiver == null ? [] : [
    "systemctl daemon-reload",
    "systemctl enable --now push-metrics.service",
  ]
}

module "isolated" {
  source = "git::https://github.com/CyprisTech/terraform-openstack-tenant.git?ref=v0.1.5"

  tenant = {
    existing = {
      networks = merge(module.planes.networks, module.bastion.existing_networks)
    }

    networks = merge({
      (local.prefix) = {
        mtu     = var.network_mtu
        subnets = { main = { cidr = var.isolated_cidr, dns_nameservers = var.dns_nameservers } }
        # The only router, to the observability plane, also the default gateway.
        routers = module.planes.routers
      }
    }, module.bastion.networks)

    security_groups = merge({
      "${local.prefix}-workload" = {
        description = "Isolated workload: SSH from the bastion only"
        rules       = merge(module.admission.rules, module.bastion.ssh_rules)
      }
    }, module.bastion.security_groups)

    instances = merge({
      (local.instance) = {
        az        = var.az
        flavor    = var.flavor
        image     = var.image
        boot      = local.boot
        user_data = module.cloudinit.rendered
        labels    = ["isolated"]
        ports = {
          main = {
            network         = local.prefix
            subnet          = "main"
            security_groups = ["${local.prefix}-workload"]
          }
        }
      }
    }, module.bastion.instances)
  }
}
