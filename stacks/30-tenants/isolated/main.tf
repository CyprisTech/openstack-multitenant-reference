# Layer 30, tenant "isolated": a workload with no public exposure and no path to the other
# tenants (ADR-0001, D5). Its network has a single router, to the monitoring plane, which
# carries the floating IP the collector scrapes. Nothing else is reachable from it, and it
# reaches nothing but the monitoring plane.
#
# The workload is a stand-in: a metrics endpoint served by the Python standard library,
# so that the instance needs no package and no Internet access.

locals {
  prefix   = "${var.site}-isolated"
  instance = "${local.prefix}-1"

  bastion_name = "${local.prefix}-bastion"
  with_bastion = var.bastion != null

  metrics_sources = coalesce(var.monitoring.collector_cidrs, [var.monitoring_plane.cidr])
  metrics_rules = {
    for pair in setproduct(var.monitoring.metrics_ports, local.metrics_sources) : "metrics-${pair[0]}-${replace(pair[1], "/", "_")}" => {
      direction = "ingress", protocol = "tcp", port_min = pair[0], port_max = pair[0], remote_ip_prefix = pair[1]
    }
  }

  ssh_rules = {
    for i, cidr in var.admin.ssh_cidrs : "ssh-${i}" => {
      direction = "ingress", protocol = "tcp", port_min = 22, port_max = 22, remote_ip_prefix = cidr
    }
  }

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

module "cloudinit_bastion" {
  source = "git::https://github.com/CyprisTech/terraform-openstack-tenant.git//modules/cloudinit?ref=fa88febb8a2676282d9995ca36396be353e667df"
  count  = local.with_bastion ? 1 : 0

  hostname = local.bastion_name
  users = {
    for login, keys in var.admin.users : login => { ssh_authorized_keys = keys, sudo = true }
  }

  # The second interface (on the isolated network) must not take the routes that DHCP pushes
  # for the isolated instance: the bastion keeps a single default route through the
  # administration network.
  write_files = {
    "/etc/netplan/60-second-interface.yaml" = {
      permissions = "0600"
      content     = <<-EOT
        network:
          version: 2
          ethernets:
            ens4:
              dhcp4: true
              dhcp4-overrides:
                use-routes: false
                use-dns: false
      EOT
    }
  }
  runcmd = ["netplan apply"]
}

module "cloudinit" {
  source = "git::https://github.com/CyprisTech/terraform-openstack-tenant.git//modules/cloudinit?ref=fa88febb8a2676282d9995ca36396be353e667df"

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
  source = "git::https://github.com/CyprisTech/terraform-openstack-tenant.git?ref=fa88febb8a2676282d9995ca36396be353e667df"

  tenant = {
    existing = {
      dns_zones = var.monitoring.dns_zone == null ? {} : { monitoring = { name = var.monitoring.dns_zone } }
      networks = merge({
        monitoring = { name = var.monitoring_plane.network, subnets = { main = { name = var.monitoring_plane.subnet } } }
        }, {
        for k in(local.with_bastion ? ["admin"] : []) : k => {
          name = try(var.bastion.external_network.network, ""), subnets = { main = { name = try(var.bastion.external_network.subnet, "") } }
        }
      })
    }

    networks = merge({
      (local.prefix) = {
        mtu = var.network_mtu
        subnets = {
          main = { cidr = var.isolated_cidr, dns_nameservers = var.dns_nameservers }
        }
        routers = {
          # The only router: it carries the monitoring floating IP and the replies to the collector.
          monitoring = { external_network = "monitoring", internal_subnet = "main", default_gateway = true }
        }
      }
      }, {
      # Administration network of the bastion: its only router joins the administration network.
      for k in(local.with_bastion ? ["${local.prefix}-admin"] : []) : k => {
        mtu     = var.network_mtu
        subnets = { main = { cidr = try(var.bastion.cidr, "10.33.0.0/28"), dns_nameservers = var.dns_nameservers } }
        routers = { admin = { external_network = "admin", internal_subnet = "main", default_gateway = true } }
      }
    })

    security_groups = merge({
      "${local.prefix}-workload" = {
        description = "Isolated workload: metrics from the collector only, SSH from the bastion"
        rules = merge(local.metrics_rules, local.ssh_rules, {
          for k in(local.with_bastion ? ["ssh-from-bastion"] : []) : k => {
            direction = "ingress", protocol = "tcp", port_min = 22, port_max = 22, remote_group = local.bastion_name
          }
        })
      }
      }, {
      for k in(local.with_bastion ? [local.bastion_name] : []) : k => {
        description = "Bastion: SSH from the administration sources"
        rules = {
          for i, cidr in try(var.bastion.ssh_cidrs, []) : "ssh-${i}" => {
            direction = "ingress", protocol = "tcp", port_min = 22, port_max = 22, remote_ip_prefix = cidr
          }
        }
      }
    })

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
            floating_ip = {
              pool = "monitoring"
              dns  = var.monitoring.dns_zone == null ? [] : [{ name = local.instance, zone = "monitoring" }]
            }
          }
        }
      }
      }, {
      for name in(local.with_bastion ? [local.bastion_name] : []) : name => {
        az        = var.az
        flavor    = coalesce(try(var.bastion.flavor, null), var.flavor)
        image     = var.image
        boot      = var.boot_volume_size == null ? { source = "image" } : { source = "volume", size = var.boot_volume_size }
        user_data = module.cloudinit_bastion[0].rendered
        labels    = ["bastion"]
        ports = {
          admin    = { network = "${local.prefix}-admin", subnet = "main", security_groups = [local.bastion_name], floating_ip = { pool = "admin" } }
          isolated = { network = local.prefix, subnet = "main", security_groups = [local.bastion_name] }
        }
      }
    })
  }
}
