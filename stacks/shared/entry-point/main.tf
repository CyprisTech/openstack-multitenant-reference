# The shared public entry point (ADR-0001, D3 and D8).
# Octavia in TCP mode, pools in PROXY protocol, two Traefik instances on plain VMs
# routing by SNI without terminating TLS.

locals {
  # Boot disk of the instances: the image's ephemeral disk, or a volume of the given size.
  boot = var.boot_volume_size == null ? { source = "image" } : { source = "volume", size = var.boot_volume_size }

  prefix = "${var.site}-edge"

  instances = ["${local.prefix}-1", "${local.prefix}-2"]
  members   = [for name in local.instances : "${name}.main"]

  bastion_name = "${local.prefix}-bastion"

}

# Who may reach the Traefik instances.
module "admission" {
  source = "../../../modules/admission"

  allow = {
    from-lb = { ports = [80, 443], sources = [var.edge_cidr] } # Octavia amphorae, on the edge network
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
    boot   = local.boot
  }
  mtu             = var.network_mtu
  dns_nameservers = var.dns_nameservers
}

# How the stack joins the planes (ADR-0004), from its entry of the attachments output of
# shared/planes. The Traefik instances have no address on the planes: they connect to the
# tenants' service addresses (ADR-0006).
module "planes" {
  source = "../../../modules/plane-attachment"

  planes     = ["publication", "observability"]
  attachment = var.plane_attachment
  instances  = local.instances
}

# The metrics agent of each instance, with the Traefik metrics: it pushes to the receiver
# (ADR-0007).
module "metrics" {
  source   = "../../../modules/metrics-agent"
  for_each = toset(local.instances)

  receiver = var.monitoring.receiver
  targets  = { node = ["localhost:9100"], traefik = ["localhost:8082"] }
  labels   = { site = var.site, tenant = "edge", instance = each.key }
}

module "cloudinit" {
  source   = "git::https://github.com/CyprisTech/terraform-openstack-tenant.git//modules/cloudinit?ref=v0.1.4"
  for_each = toset(local.instances)

  hostname = each.key
  users = {
    for login, keys in var.admin.users : login => { ssh_authorized_keys = keys, sudo = true }
  }
  packages = concat(["podman"], module.metrics[each.key].packages)
  # A mirror error at first boot would leave the instance without its packages, silently.
  extra_config = { apt = { conf = "Acquire::Retries \"10\";\n" } }

  write_files = merge({
    "/etc/traefik/traefik.yml" = {
      content = local.traefik_static
    }
    "/etc/systemd/system/traefik.service" = {
      content = local.traefik_unit
    }
    "/usr/local/sbin/traefik-routes" = {
      content     = local.traefik_routes
      permissions = "0755"
    }
    "/etc/systemd/system/traefik-routes.service" = {
      content = local.traefik_routes_units["/etc/systemd/system/traefik-routes.service"]
    }
    "/etc/systemd/system/traefik-routes.timer" = {
      content = local.traefik_routes_units["/etc/systemd/system/traefik-routes.timer"]
    }
  }, module.metrics[each.key].write_files)

  # The routes are rendered before Traefik starts, then every 10 seconds.
  runcmd = concat([
    "mkdir -p /etc/traefik/dynamic",
    "/usr/local/sbin/traefik-routes",
    "systemctl daemon-reload",
    "systemctl enable --now traefik-routes.timer traefik.service",
  ], module.metrics[each.key].runcmd)
}

module "edge" {
  # Git source: works with OpenTofu and Terraform alike (registry: CyprisTech/tenant/openstack).
  source = "git::https://github.com/CyprisTech/terraform-openstack-tenant.git?ref=v0.1.4"

  tenant = {
    existing = {
      networks = merge({
        public        = { name = var.public_network.network, subnets = { main = { name = var.public_network.subnet } } }
        publication   = module.planes.networks.publication
        observability = module.planes.networks.observability
      }, module.bastion.existing_networks)
      dns_zones = var.public_dns == null ? {} : { public = { name = var.public_dns.zone } }
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
          publication   = module.planes.routers["publication"]
          observability = module.planes.routers["observability"]
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
        boot         = local.boot
        server_group = local.prefix
        user_data    = module.cloudinit[name].rendered
        metadata     = local.route_metadata # the routes, updated in place (ADR-0006, D3)
        labels       = ["edge", "traefik"]
        ports = {
          main = {
            network         = local.prefix
            subnet          = "main"
            security_groups = ["${local.prefix}-proxy"]
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

# Address under which the edge reaches publication in gateway mode: backends admit it in their
# security groups (ADR-0001, D7). Read from the router, never written by hand (D9). In interface
# mode there is no translation: backends admit the edge range.
data "openstack_networking_router_v2" "publication" {
  count     = module.planes.nat.publication ? 1 : 0
  router_id = module.edge.networks[local.prefix].routers["publication"].id
}
