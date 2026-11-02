# Tenant of virtual machines: two VMs serving several domains, published on the svc_public
# plane and reachable only from the public entry point (ADR-0001, D5 and D7).
#
# The web server is a demonstration backend: nginx terminates TLS with a self-signed
# certificate, reads the PROXY protocol v2 header sent by the entry point and answers
# with the client address it received. A real backend would obtain its certificates
# with a DNS-01 or TLS-ALPN-01 challenge.

locals {
  prefix = "${var.site}-web"

  instances = ["${local.prefix}-1", "${local.prefix}-2"]

  # Ranges of the entry point on svc_public, from its output svc_public_sources: only they may
  # reach the published port, and only they are trusted to send a PROXY protocol header.
  edge_sources = var.edge_sources

  # Sources of the metrics scrapes: the collector only.
  metrics_sources = coalesce(var.monitoring.collector_cidrs, [module.planes.cidr.monitoring])

  bastion_name = "${local.prefix}-bastion"

  nginx_conf = <<-EOT
    server {
        listen 443 ssl proxy_protocol default_server;
        ssl_certificate     /etc/nginx/tls/cert.pem;
        ssl_certificate_key /etc/nginx/tls/key.pem;

    %{for cidr in local.edge_sources~}
        set_real_ip_from ${cidr};
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

# Who may reach the web instances.
module "admission" {
  source = "../../../modules/admission"

  allow = {
    https-from-edge = { ports = [443], sources = local.edge_sources }
    metrics         = { ports = var.monitoring.metrics_ports, sources = local.metrics_sources }
    ssh             = { ports = [22], sources = var.admin.ssh_cidrs }
  }
}

module "bastion" {
  source = "../../../modules/bastion"

  name          = local.bastion_name
  bastion       = var.bastion
  admin_network = "${local.prefix}-admin"
  default_cidr  = "10.31.0.0/28"
  network       = local.prefix
  port          = "web"
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
    primary = "svc_public"
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
  packages = ["nginx", "prometheus-node-exporter"]

  write_files = {
    "/etc/nginx/conf.d/web.conf" = { content = local.nginx_conf }
  }

  # The certificate must exist before the nginx package starts the service with this
  # configuration: bootcmd runs before package installation (and at every boot, hence the test).
  # apt retries: a mirror error at first boot would leave the instance without its packages,
  # silently.
  extra_config = {
    apt = { conf = "Acquire::Retries \"10\";\n" }
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
  source = "git::https://github.com/CyprisTech/terraform-openstack-tenant.git?ref=84c898b5d5036296a7cd3496a54e0721ccbc4936"

  tenant = {
    existing = {
      dns_zones = var.monitoring.dns_zone == null ? {} : { monitoring = { name = var.monitoring.dns_zone } }
      networks = merge({
        egress     = { name = var.egress_network.network, subnets = { main = { name = var.egress_network.subnet } } }
        svc_public = module.planes.networks.svc_public
        monitoring = module.planes.networks.monitoring
      }, module.bastion.existing_networks)
    }

    networks = merge({
      (local.prefix) = {
        mtu = var.network_mtu
        subnets = {
          main = { cidr = var.web_cidr, dns_nameservers = var.dns_nameservers }
        }
        routers = {
          egress = { external_network = "egress", internal_subnet = "main", default_gateway = true }
          # Gateway mode: the published addresses are floating IPs of this router on svc_public.
          # Interface mode: the instances' own addresses, reached through the routes.
          svc-public = module.planes.routers["svc-public"]
          monitoring = module.planes.routers["monitoring"]
        }
      }
    }, module.bastion.networks)

    security_groups = merge({
      "${local.prefix}-https" = {
        description = "Web instances: HTTPS from the public entry point only, SSH from the bastion"
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
        labels       = ["web"]
        ports = {
          main = {
            network         = local.prefix
            subnet          = "main"
            security_groups = ["${local.prefix}-https"]
            # Exposure on the planes (ADR-0001, D2): floating IPs in gateway mode, the
            # instance's own address in interface mode.
            floating_ip        = module.planes.ports[name].floating_ip
            extra_floating_ips = module.planes.ports[name].extra_floating_ips
            dns                = module.planes.ports[name].dns
          }
        }
      }
    }, module.bastion.instances)
  }
}
