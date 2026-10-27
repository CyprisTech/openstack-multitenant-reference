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
  bastion_name = "${local.prefix}-bastion"
  with_bastion = var.bastion != null

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

module "cloudinit_bastion" {
  source = "git::https://github.com/CyprisTech/terraform-openstack-tenant.git//modules/cloudinit?ref=v0.1.1"
  count  = local.with_bastion ? 1 : 0

  hostname = local.bastion_name
  users = {
    for login, keys in var.admin.users : login => { ssh_authorized_keys = keys, sudo = true }
  }

  # The second interface (on the web network) must not take the routes and resolvers that
  # DHCP pushes for the web instances: the bastion keeps a single default route through the
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

  # The certificate must exist before the nginx package starts the service with this
  # configuration: bootcmd runs before package installation (and at every boot, hence the test).
  extra_config = {
    bootcmd = [
      "mkdir -p /etc/nginx/tls",
      "test -f /etc/nginx/tls/cert.pem || openssl req -x509 -newkey rsa:2048 -nodes -days 90 -subj /CN=${var.domains[0]} -addext subjectAltName=${local.san} -keyout /etc/nginx/tls/key.pem -out /etc/nginx/tls/cert.pem",
    ]
  }

  runcmd = [
    "rm -f /etc/nginx/sites-enabled/default",
    "systemctl restart nginx",
  ]
}

module "web" {
  source = "git::https://github.com/CyprisTech/terraform-openstack-tenant.git?ref=v0.1.1"

  tenant = {
    existing = {
      networks = merge({
        egress     = { name = var.egress_network.network, subnets = { main = { name = var.egress_network.subnet } } }
        svc_public = { name = var.planes.svc_public.network, subnets = { main = { name = var.planes.svc_public.subnet } } }
        monitoring = { name = var.planes.monitoring.network, subnets = { main = { name = var.planes.monitoring.subnet } } }
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
      }, {
      # Administration network of the bastion: its only router joins the administration network.
      for k in(local.with_bastion ? ["${local.prefix}-admin"] : []) : k => {
        mtu     = var.network_mtu
        subnets = { main = { cidr = try(var.bastion.cidr, "10.31.0.0/28"), dns_nameservers = var.dns_nameservers } }
        routers = { admin = { external_network = "admin", internal_subnet = "main", default_gateway = true } }
      }
    })

    security_groups = merge({
      "${local.prefix}-https" = {
        description = "Web instances: HTTPS from the public entry point only, SSH from the bastion"
        rules = merge(local.https_rules, local.ssh_rules, {
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
      }, {
      for name in(local.with_bastion ? [local.bastion_name] : []) : name => {
        az           = var.az
        flavor       = coalesce(try(var.bastion.flavor, null), var.flavor)
        image        = var.image
        boot         = var.boot_volume_size == null ? { source = "image" } : { source = "volume", size = var.boot_volume_size }
        server_group = null
        user_data    = module.cloudinit_bastion[0].rendered
        labels       = ["bastion"]
        ports = {
          # Primary port: default route and floating IP on the administration network.
          admin = {
            network         = "${local.prefix}-admin"
            subnet          = "main"
            security_groups = [local.bastion_name]
            floating_ip     = { pool = "admin" }
          }
          # Second port on the web network, without a gateway of its own.
          web = {
            network         = local.prefix
            subnet          = "main"
            security_groups = [local.bastion_name]
            floating_ip     = null
          }
        }
      }
    })
  }
}
