# Layer 20: the public entry point (ADR-0001, D3 and D8).
# Octavia in TCP mode, pools in PROXY protocol, two Traefik instances on plain VMs
# routing by SNI without terminating TLS.

locals {
  prefix    = "${var.site}-edge"
  instances = ["${local.prefix}-1", "${local.prefix}-2"]
  members   = [for name in local.instances : "${name}.main"]

  ssh_rules = {
    for i, cidr in var.admin.ssh_cidrs : "ssh-${i}" => {
      direction = "ingress", protocol = "tcp", port_min = 22, port_max = 22, remote_ip_prefix = cidr
    }
  }
}

module "cloudinit" {
  source   = "git::https://github.com/CyprisTech/terraform-openstack-tenant.git//modules/cloudinit?ref=v0.1.1"
  for_each = toset(local.instances)

  hostname = each.key
  users = {
    for login, keys in var.admin.users : login => { ssh_authorized_keys = keys, sudo = true }
  }
  packages = ["podman"]

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
  source = "git::https://github.com/CyprisTech/terraform-openstack-tenant.git?ref=v0.1.1"

  tenant = {
    existing = {
      networks = {
        public     = { name = var.public_network.network, subnets = { main = { name = var.public_network.subnet } } }
        svc_public = { name = var.planes.svc_public.network, subnets = { main = { name = var.planes.svc_public.subnet } } }
        monitoring = { name = var.planes.monitoring.network, subnets = { main = { name = var.planes.monitoring.subnet } } }
      }
      dns_zones = var.public_dns == null ? {} : { public = { name = var.public_dns.zone } }
    }

    networks = {
      (local.prefix) = {
        subnets = {
          main = { cidr = var.edge_cidr, dns_nameservers = var.dns_nameservers }
        }
        routers = {
          # Default route and public floating IP.
          public = { external_network = "public", internal_subnet = "main", default_gateway = true }
          # Plane routers: their routes are pushed to the instances by DHCP (ADR-0001, D2).
          svc-public = {
            external_network = "svc_public", internal_subnet = "main",
            advertise_routes = [var.planes.svc_public.cidr]
          }
          monitoring = {
            external_network = "monitoring", internal_subnet = "main",
            advertise_routes = [var.planes.monitoring.cidr]
          }
        }
      }
    }

    security_groups = {
      "${local.prefix}-proxy" = {
        description = "Traefik instances of the public entry point"
        rules = merge({
          # Octavia amphorae connect from the edge network.
          http    = { direction = "ingress", protocol = "tcp", port_min = 80, port_max = 80, remote_ip_prefix = var.edge_cidr }
          https   = { direction = "ingress", protocol = "tcp", port_min = 443, port_max = 443, remote_ip_prefix = var.edge_cidr }
          metrics = { direction = "ingress", protocol = "tcp", port_min = 8082, port_max = 8082, remote_ip_prefix = var.planes.monitoring.cidr }
        }, local.ssh_rules)
      }
    }

    server_groups = {
      (local.prefix) = { policy = var.server_group_policy }
    }

    instances = {
      for name in local.instances : name => {
        az           = var.az
        flavor       = var.flavor
        image        = var.image
        boot         = var.boot_volume_size == null ? { source = "image" } : { source = "volume", size = var.boot_volume_size }
        server_group = local.prefix
        user_data    = module.cloudinit[name].rendered
        labels       = ["edge", "traefik"]
        ports = {
          main = { network = local.prefix, subnet = "main", security_groups = ["${local.prefix}-proxy"] }
        }
      }
    }

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

# Address under which the edge reaches svc_public: backends admit it in their security
# groups (ADR-0001, D7). Read from the router, never written by hand (D9).
data "openstack_networking_router_v2" "svc_public" {
  router_id = module.edge.networks[local.prefix].routers["svc-public"].id
}
