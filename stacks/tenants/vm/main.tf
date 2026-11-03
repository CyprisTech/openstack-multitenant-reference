# Tenant of virtual machines serving several domains behind one service address (ADR-0006): its
# load balancer, or its instance when it has only one. Published through the shared entry point,
# or with its own public floating IP.
#
# The web server is a demonstration backend: nginx terminates TLS with a self-signed
# certificate, reads the PROXY protocol v2 header sent by the entry point and answers
# with the client address it received. A real backend would obtain its certificates
# with a DNS-01 or TLS-ALPN-01 challenge.

locals {
  prefix = "${var.site}-web"

  instances = [for i in range(var.instance_count) : "${local.prefix}-${i + 1}"]

  # One service address (ADR-0006, D1): a load balancer in front of several instances.
  load_balancer = var.instance_count > 1
  public        = var.exposure == "public"

  # Ranges of the entry point on svc_public, from its output svc_public_sources: only they may
  # reach the service address.
  edge_sources = var.edge_sources

  # Who connects to the instances on 443: the amphorae of the load balancer, on the web network;
  # without one, the entry point, or anyone when the instance is exposed directly.
  https_sources = local.load_balancer ? [var.web_cidr] : (local.public ? ["0.0.0.0/0"] : local.edge_sources)

  # A PROXY protocol header comes from the entry point or from the load balancer; an instance
  # exposed directly receives none.
  proxy_protocol = local.load_balancer || !local.public

  bastion_name = "${local.prefix}-bastion"

  nginx_conf = <<-EOT
    server {
        listen 443 ssl%{if local.proxy_protocol} proxy_protocol%{endif} default_server;
        ssl_certificate     /etc/nginx/tls/cert.pem;
        ssl_certificate_key /etc/nginx/tls/key.pem;

    %{if local.proxy_protocol~}
    %{for cidr in local.https_sources~}
        set_real_ip_from ${cidr};
    %{endfor~}
        real_ip_header proxy_protocol;
    %{endif~}

        location / {
            default_type text/plain;
            return 200 "host=$host server=$hostname client=$remote_addr\n";
        }
    }
  EOT

  san = join(",", [for d in var.domains : "DNS:${d}"])
}

# Who may reach the web instances.
resource "terraform_data" "checks" {
  lifecycle {
    precondition {
      condition     = var.exposure != "entry-point" || length(var.edge_sources) > 0
      error_message = "exposure = \"entry-point\" needs edge_sources: output svc_public_sources of stack shared/entry-point."
    }
  }
}

module "admission" {
  source = "../../../modules/admission"

  allow = {
    https = { ports = [443], sources = local.https_sources }
    ssh   = { ports = [22], sources = var.admin.ssh_cidrs }
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
    # A single instance is the service address; behind a load balancer, instances have none.
    primary = local.load_balancer || local.public ? null : "svc_public"
  }
}

# The metrics agent of each instance: it pushes to the receiver (ADR-0007).
module "metrics" {
  source   = "../../../modules/metrics-agent"
  for_each = toset(local.instances)

  receiver = var.monitoring.receiver
  labels   = { site = var.site, tenant = "web", instance = each.key }
}

module "cloudinit" {
  source   = "git::https://github.com/CyprisTech/terraform-openstack-tenant.git//modules/cloudinit?ref=v0.1.4"
  for_each = toset(local.instances)

  hostname = each.key
  users = {
    for login, keys in var.admin.users : login => { ssh_authorized_keys = keys, sudo = true }
  }
  packages = concat(["nginx"], module.metrics[each.key].packages)

  write_files = merge({
    "/etc/nginx/conf.d/web.conf" = { content = local.nginx_conf }
  }, module.metrics[each.key].write_files)

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

  runcmd = concat([
    "rm -f /etc/nginx/sites-enabled/default",
    "systemctl restart nginx",
  ], module.metrics[each.key].runcmd)
}

module "web" {
  source = "git::https://github.com/CyprisTech/terraform-openstack-tenant.git?ref=v0.1.4"

  tenant = {
    existing = {
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

    load_balancers = local.load_balancer ? {
      (local.prefix) = {
        vip = { network = local.prefix, subnet = "main" }
        # The service address: on svc_public (a floating IP of the plane when it translates
        # addresses, the VIP itself otherwise), or a public floating IP.
        floating_ip = local.public ? { pool = "egress" } : (module.planes.nat.svc_public ? { pool = "svc_public" } : null)
        listeners = {
          https = {
            protocol      = "TCP", port = 443
            allowed_cidrs = local.public ? [] : local.edge_sources
            # Through the entry point, its PROXY header passes through; exposed directly, the
            # load balancer adds one.
            pool = {
              protocol = local.public ? "PROXYV2" : "TCP"
              members  = [for name in local.instances : "${name}.main"]
              monitor  = { type = "TCP" }
            }
          }
        }
      }
    } : {}

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
            # A single instance is the service address (ADR-0006, D1): a floating IP of
            # svc_public when the plane translates addresses, a public one with exposure "public".
            floating_ip = !local.load_balancer && local.public ? { pool = "egress" } : module.planes.ports[name].floating_ip
          }
        }
      }
    }, module.bastion.instances)
  }
}
