# Layer 30, tenant "web": two VMs serving several domains, published on the svc_public
# plane and reachable only from the public entry point (ADR-0001, D5 and D7).
#
# The web server is a demonstration backend: nginx terminates TLS with a self-signed
# certificate, reads the PROXY protocol v2 header sent by the entry point and answers
# with the client address it received. A real backend would obtain its certificates
# with a DNS-01 or TLS-ALPN-01 challenge.

locals {
  prefix    = "${var.site}-web"
  instances = ["${local.prefix}-1", "${local.prefix}-2"]

  # Addresses of the entry point on svc_public, read from its router by name (ADR-0001, D1
  # and D9): only they may reach the published port, and only they are trusted to send a
  # PROXY protocol header.
  edge_sources = [for ip in data.openstack_networking_router_v2.edge_svc_public.external_fixed_ip : ip.ip_address]

  https_rules = {
    for i, ip in local.edge_sources : "https-from-edge-${i}" => {
      direction = "ingress", protocol = "tcp", port_min = 443, port_max = 443, remote_ip_prefix = "${ip}/32"
    }
  }
  ssh_rules = {
    for i, cidr in var.admin.ssh_cidrs : "ssh-${i}" => {
      direction = "ingress", protocol = "tcp", port_min = 22, port_max = 22, remote_ip_prefix = cidr
    }
  }

  nginx_conf = <<-EOT
    server {
        listen 443 ssl proxy_protocol default_server;
        ssl_certificate     /etc/nginx/tls/cert.pem;
        ssl_certificate_key /etc/nginx/tls/key.pem;

    %{for ip in local.edge_sources~}
        set_real_ip_from ${ip};
    %{endfor~}
        real_ip_header proxy_protocol;

        location / {
            default_type text/plain;
            return 200 "host=$host server=$hostname client=$remote_addr\n";
        }
    }
  EOT

  san = join(",", [for d in var.domains : "DNS:${d}"])
}

data "openstack_networking_router_v2" "edge_svc_public" {
  name = "${var.site}-edge-svc-public"
}

module "cloudinit" {
  source   = "git::https://github.com/CyprisTech/terraform-openstack-tenant.git//modules/cloudinit?ref=v0.1.1"
  for_each = toset(local.instances)

  hostname = each.key
  users = {
    for login, keys in var.admin.users : login => { ssh_authorized_keys = keys, sudo = true }
  }
  packages = ["nginx"]

  write_files = {
    "/etc/nginx/conf.d/web.conf" = { content = local.nginx_conf }
  }

  runcmd = [
    "mkdir -p /etc/nginx/tls",
    "openssl req -x509 -newkey rsa:2048 -nodes -days 90 -subj /CN=${var.domains[0]} -addext subjectAltName=${local.san} -keyout /etc/nginx/tls/key.pem -out /etc/nginx/tls/cert.pem",
    "rm -f /etc/nginx/sites-enabled/default",
    "systemctl restart nginx",
  ]
}

module "web" {
  source = "git::https://github.com/CyprisTech/terraform-openstack-tenant.git?ref=v0.1.1"

  tenant = {
    existing = {
      networks = {
        egress     = { name = var.egress_network.network, subnets = { main = { name = var.egress_network.subnet } } }
        svc_public = { name = var.planes.svc_public.network, subnets = { main = { name = var.planes.svc_public.subnet } } }
        monitoring = { name = var.planes.monitoring.network, subnets = { main = { name = var.planes.monitoring.subnet } } }
      }
    }

    networks = {
      (local.prefix) = {
        subnets = {
          main = { cidr = var.web_cidr, dns_nameservers = var.dns_nameservers }
        }
        routers = {
          egress = { external_network = "egress", internal_subnet = "main", default_gateway = true }
          # The published addresses are floating IPs of this router on svc_public.
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
      "${local.prefix}-https" = {
        description = "Web instances: HTTPS from the public entry point only"
        rules       = merge(local.https_rules, local.ssh_rules)
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
        labels       = ["web"]
        ports = {
          main = {
            network         = local.prefix
            subnet          = "main"
            security_groups = ["${local.prefix}-https"]
            floating_ip     = { pool = "svc_public" }
          }
        }
      }
    }
  }
}
