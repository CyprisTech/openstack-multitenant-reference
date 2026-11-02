# The shared public entry point (ADR-0001, D3 and D8).
# Octavia in TCP mode, pools in PROXY protocol, two Traefik instances on plain VMs
# routing by SNI without terminating TLS.

locals {
  prefix = "${var.site}-edge"

  instances = ["${local.prefix}-1", "${local.prefix}-2"]
  members   = [for name in local.instances : "${name}.main"]

  # Traefik metrics (8082) and the metrics ports of the instances, from the collector only.
  metrics_sources = coalesce(var.monitoring.collector_cidrs, [module.planes.cidr.monitoring])

  bastion_name = "${local.prefix}-bastion"

}

# Who may reach the Traefik instances.
module "admission" {
  source = "../../../modules/admission"

  allow = {
    from-lb = { ports = [80, 443], sources = [var.edge_cidr] } # Octavia amphorae, on the edge network
    metrics = { ports = concat([8082], var.monitoring.metrics_ports), sources = local.metrics_sources }
    ssh     = { ports = [22], sources = var.admin.ssh_cidrs }
  }
}

module "bastion" {
  source = "../../../modules/bastion"

  name          = local.bastion_name
  bastion       = var.bastion
  admin_network = "${local.prefix}-admin"
  default_cidr  = "10.32.0.0/28"
  network       = local.prefix
  port          = "edge"
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

# How the stack joins the planes (ADR-0004), from its entry of the attachments output of
# shared/planes.
module "planes" {
  source = "../../../modules/plane-attachment"

  planes     = ["svc_public", "monitoring"]
  attachment = var.plane_attachment
  instances  = local.instances
  exposure = {
    primary = null
    extra   = ["monitoring"]
    dns     = var.monitoring.dns_zone == null ? null : { plane = "monitoring", zone = "monitoring" }
  }
}

module "cloudinit" {
  source   = "git::https://github.com/CyprisTech/terraform-openstack-tenant.git//modules/cloudinit?ref=v0.1.3"
  for_each = toset(local.instances)

  hostname = each.key
  users = {
    for login, keys in var.admin.users : login => { ssh_authorized_keys = keys, sudo = true }
  }
  packages = ["podman", "prometheus-node-exporter"]
  # A mirror error at first boot would leave the instance without its packages, silently.
  extra_config = { apt = { conf = "Acquire::Retries \"10\";\n" } }

  write_files = {
    "/etc/traefik/traefik.yml" = {
      content = local.traefik_static
    }
    "/etc/traefik/dynamic.yml" = {
      content = local.traefik_dynamic
    }
    "/etc/systemd/system/traefik.service" = {
      content = local.traefik_unit
    }
  }

  runcmd = [
    "systemctl daemon-reload",
    "systemctl enable --now traefik.service",
  ]
}

module "edge" {
  # Git source: works with OpenTofu and Terraform alike (registry: CyprisTech/tenant/openstack).
  source = "git::https://github.com/CyprisTech/terraform-openstack-tenant.git?ref=84c898b5d5036296a7cd3496a54e0721ccbc4936"

  tenant = {
    existing = {
      networks = merge({
        public     = { name = var.public_network.network, subnets = { main = { name = var.public_network.subnet } } }
        svc_public = module.planes.networks.svc_public
        monitoring = module.planes.networks.monitoring
      }, module.bastion.existing_networks)
      dns_zones = merge(
        var.public_dns == null ? {} : { public = { name = var.public_dns.zone } },
        var.monitoring.dns_zone == null ? {} : { monitoring = { name = var.monitoring.dns_zone } },
      )
    }

    networks = merge({
      (local.prefix) = {
        mtu = var.network_mtu
        subnets = {
          main = { cidr = var.edge_cidr, dns_nameservers = var.dns_nameservers }
        }
        routers = {
          # Default route and public floating IP.
          public = { external_network = "public", internal_subnet = "main", default_gateway = true }
          # Plane routers: their routes are pushed to the instances by DHCP (ADR-0001, D2).
          svc-public = module.planes.routers["svc-public"]
          monitoring = module.planes.routers["monitoring"]
        }
      }
    }, module.bastion.networks)

    security_groups = merge({
      "${local.prefix}-proxy" = {
        description = "Traefik instances of the public entry point"
        rules       = merge(module.admission.rules, module.bastion.ssh_rules)
      }
    }, module.bastion.security_groups)

    server_groups = {
      (local.prefix) = { policy = var.server_group_policy }
    }

    instances = merge({
      for name in local.instances : name => {
        az           = var.az
        flavor       = var.flavor
        image        = var.image
        boot         = var.boot_volume_size == null ? { source = "image" } : { source = "volume", size = var.boot_volume_size }
        server_group = local.prefix
        user_data    = module.cloudinit[name].rendered
        labels       = ["edge", "traefik"]
        ports = {
          main = {
            network         = local.prefix
            subnet          = "main"
            security_groups = ["${local.prefix}-proxy"]
            # Exposure on the planes (ADR-0001, D2): floating IPs in gateway mode, the
            # instance's own address in interface mode.
            floating_ip        = module.planes.ports[name].floating_ip
            extra_floating_ips = module.planes.ports[name].extra_floating_ips
            dns                = module.planes.ports[name].dns
          }
        }
      }
    }, module.bastion.instances)

    load_balancers = {
      (local.prefix) = {
        vip       = { network = local.prefix, subnet = "main" }
        flavor_id = var.octavia_flavor_id
        floating_ip = {
          pool = "public"
          dns  = var.public_dns == null ? [] : [for n in var.public_dns.names : { name = n, zone = "public" }]
        }
        listeners = {
          # Both listeners forward raw TCP with a PROXY header: Traefik sees the client address
          # and redirects port 80 to HTTPS itself (ADR-0001, D3).
          http = {
            protocol = "TCP", port = 80
            pool = {
              protocol = "PROXY", members = local.members
              monitor  = { type = "TCP" }
            }
          }
          https = {
            protocol = "TCP", port = 443
            pool = {
              protocol = "PROXY", members = local.members
              monitor  = { type = "TCP" }
            }
          }
        }
      }
    }

    defaults = var.public_dns == null ? {} : { ttl = var.public_dns.ttl }
  }
}

# Address under which the edge reaches svc_public in gateway mode: backends admit it in their
# security groups (ADR-0001, D7). Read from the router, never written by hand (D9). In interface
# mode there is no translation: backends admit the edge range.
data "openstack_networking_router_v2" "svc_public" {
  count     = module.planes.nat.svc_public ? 1 : 0
  router_id = module.edge.networks[local.prefix].routers["svc-public"].id
}
