# Tenant of virtual machines (ADR-0003, D3), its exposure and its egress declared (ADR-0016, D1).
# Exposed, it serves several domains behind one service address (ADR-0006): its load balancer, or
# its instance when it has only one, published through the shared entry point or with its own
# public floating IP. With neither exposure nor egress, it is a private tenant.
#
# With an egress, the workload is a demonstration web server: nginx terminates TLS, reads the
# PROXY protocol v2 header sent by the entry point and answers with the client address it
# received. Its certificate comes from an ACME directory through the DNS-01 challenge (lego,
# ADR-0008), or is self-signed in demonstration mode, without certificates. Without egress, the
# instances install nothing: a stand-in from the image's Python pushes one metric to the receiver.

locals {
  prefix = "${var.site}-${var.name}"

  instances = [for i in range(var.instance_count) : "${local.prefix}-${i + 1}"]

  # Boot disk of the instances: the image's ephemeral disk, or a volume of the given size.
  boot = var.boot_volume_size == null ? { source = "image" } : { source = "volume", size = var.boot_volume_size }

  # Availability zones (ADR-0012): the instances of a role are spread over the zones in order,
  # the single ones (bastion) go to the first. A root volume takes the storage zone mapped to
  # the instance's zone, or the cloud's default.
  zone_of = { for i, name in local.instances : name => var.zones[i % length(var.zones)] }
  boot_in = { for z in var.zones : z => merge(local.boot, { az = local.boot.source == "volume" ? lookup(var.volume_zones, z, null) : null }) }

  # Exposure and egress (ADR-0016, D1).
  exposed = var.exposure != "none"
  public  = var.exposure == "public"
  egress  = var.egress == "router"

  # One service address (ADR-0006, D1): a load balancer in front of several instances.
  load_balancer = local.exposed && var.instance_count > 1

  # Ranges of the entry point on publication, from its output publication_sources: only they may
  # reach the service address.
  edge_sources = var.edge_sources

  # Who connects to the instances on 443: the amphorae of the load balancer, on the web network;
  # without one, the entry point, or anyone when the instance is exposed directly.
  https_sources = !local.exposed ? [] : local.load_balancer ? [var.web_cidr] : (local.public ? ["0.0.0.0/0"] : local.edge_sources)

  # A PROXY protocol header comes from the entry point or from the load balancer; an instance
  # exposed directly receives none.
  proxy_protocol = local.load_balancer || !local.public

  bastion_name = "${local.prefix}-bastion"

  # Demonstration backend: answers with the host, the server and the client address it received.
  nginx_conf = templatefile("${path.module}/files/nginx.conf.tftpl", {
    proxy_protocol = local.proxy_protocol
    https_sources  = local.https_sources
  })

  san = join(",", [for d in var.domains : "DNS:${d}"])

  # Certificates (ADR-0008): obtained by the ACME client, or self-signed in demonstration mode.
  acme = var.certificates != null
}

# Demonstration mode: a warning at every plan and apply, without failing. A private tenant
# serves nothing: no certificate.
check "certificates" {
  assert {
    condition     = var.certificates != null || !local.exposed
    error_message = "certificates not set: self-signed certificate, for evaluation only (ADR-0008)."
  }
}

# Who may reach the web instances.
resource "terraform_data" "checks" {
  lifecycle {
    precondition {
      condition     = var.exposure != "entry-point" || length(var.edge_sources) > 0
      error_message = "exposure = \"entry-point\" needs edge_sources: output publication_sources of stack shared/entry-point."
    }
  }
}

module "admission" {
  source = "../../../modules/admission"

  allow = merge(local.exposed ? {
    https = { ports = [443], sources = local.https_sources }
    } : {}, {
    ssh = { ports = [22], sources = var.admin.ssh_cidrs }
  })
}

module "bastion" {
  source = "../../../modules/bastion"

  name          = local.bastion_name
  bastion       = var.bastion
  placement     = var.bastion_placement
  admin_network = "${local.prefix}-admin"
  default_cidr  = "10.31.0.0/28"
  network       = local.prefix
  port          = "web"
  egress        = local.egress ? { pool = "egress", network = var.egress_network.network } : null
  users         = var.admin.users
  instance = {
    az     = var.zones[0]
    image  = var.image
    flavor = var.flavor
    boot   = local.boot_in[var.zones[0]]
  }
  mtu             = var.network_mtu
  dns_nameservers = var.dns_nameservers
}

# How the stack joins the planes (ADR-0004), from its entry of the attachments output of
# shared/planes.
module "planes" {
  source = "../../../modules/plane-attachment"

  # The internal services plane when the attachment has it: the tenant consumes internal services,
  # such as the organisation's certificate authority.
  # The publication plane only through the entry point: exposed directly, the tenant has no
  # router there, and the entry point cannot reach it.
  planes     = concat(var.exposure == "entry-point" ? ["publication"] : [], ["observability"], contains(keys(var.plane_attachment), "internal") ? ["internal"] : [])
  attachment = var.plane_attachment
  # The transit router sends the default route to the egress router; without egress, there is no
  # default route: unknown destinations are dropped.
  default_router = local.egress ? "egress" : null
  instances      = local.instances
  exposure = {
    # A single instance is the service address; behind a load balancer, instances have none.
    primary = var.exposure == "entry-point" && !local.load_balancer ? "publication" : null
  }
}

# The ACME client of the instances (ADR-0008): lego, installing the certificate for nginx and
# enabling the site once the certificate is issued.
module "acme" {
  source = "../../../modules/acme-client"

  certificates     = var.certificates
  domains          = var.domains
  lego_version     = var.lego_version
  certificate_path = "/etc/nginx/tls/cert.pem"
  key_path         = "/etc/nginx/tls/key.pem"
  deploy_commands  = ["ln -sf /etc/nginx/web.conf /etc/nginx/conf.d/web.conf", "systemctl reload nginx"]
}

# The metrics agent of each instance: it pushes to the receiver (ADR-0007). Its packages need the
# egress; without it, the stand-in workload pushes its own metric.
module "metrics" {
  source   = "../../../modules/metrics-agent"
  for_each = toset(local.egress ? local.instances : [])

  receiver = var.monitoring.receiver
  labels   = { site = var.site, tenant = var.name, instance = each.key }
}

# Without egress: a stand-in workload from the image's Python, pushing one metric (OTLP).
locals {
  standin_files = {
    for name in local.instances : name => local.egress || var.monitoring.receiver == null ? {} : {
      "/usr/local/bin/push-metrics" = {
        content     = templatefile("${path.module}/files/push-metrics.py.tftpl", { instance = name, site = var.site, tenant = var.name })
        permissions = "0755"
      }
      "/etc/systemd/system/push-metrics.service" = {
        content = templatefile("${path.module}/files/push-metrics.service.tftpl", { receiver = var.monitoring.receiver })
      }
    }
  }
  standin_runcmd = local.egress || var.monitoring.receiver == null ? [] : ["systemctl daemon-reload", "systemctl enable --now push-metrics.service"]
}

module "cloudinit" {
  source   = "git::https://github.com/CyprisTech/terraform-openstack-tenant.git//modules/cloudinit?ref=v0.1.6"
  for_each = toset(local.instances)

  hostname       = each.key
  package_update = local.egress
  users = {
    for login, keys in var.admin.users : login => { ssh_authorized_keys = keys, sudo = true }
  }
  packages = local.egress ? concat(["nginx"], try(module.metrics[each.key].packages, [])) : []

  # With certificates, the site is enabled by the deploy hook once the certificate is issued:
  # until then nothing listens on 443 and the load balancer keeps the instance out of its pool.
  write_files = merge(local.standin_files[each.key], [for f in [merge(
    local.acme ? { "/etc/nginx/web.conf" = { content = local.nginx_conf } } : { "/etc/nginx/conf.d/web.conf" = { content = local.nginx_conf } },
    module.acme.write_files,
    try(module.metrics[each.key].write_files, {}),
  )] : f if local.egress]...)

  # Demonstration mode: the certificate must exist before the nginx package starts the service
  # with this configuration; bootcmd runs before package installation (and at every boot, hence
  # the test). apt retries: a mirror error at first boot would leave the instance without its
  # packages, silently.
  # (A conditional of objects needs one type: the settings are kept, or not, through a list.)
  extra_config = merge({}, [for c in [{
    apt = { conf = "Acquire::Retries \"10\";\n" }
    bootcmd = concat(["mkdir -p /etc/nginx/tls"], local.acme ? [] : [
      "test -f /etc/nginx/tls/cert.pem || openssl req -x509 -newkey rsa:2048 -nodes -days 90 -subj /CN=${var.domains[0]} -addext subjectAltName=${local.san} -keyout /etc/nginx/tls/key.pem -out /etc/nginx/tls/cert.pem",
    ])
  }] : c if local.egress]...)

  runcmd = local.egress ? concat([
    "rm -f /etc/nginx/sites-enabled/default",
    "systemctl restart nginx",
  ], module.acme.runcmd, try(module.metrics[each.key].runcmd, [])) : local.standin_runcmd
}

module "web" {
  source = "git::https://github.com/CyprisTech/terraform-openstack-tenant.git?ref=v0.1.6"

  tenant = {
    existing = {
      networks = merge(local.egress ? {
        egress = { name = var.egress_network.network, subnets = { for k, s in { main = var.egress_network.subnet } : k => { name = s } if s != null } }
      } : {}, module.planes.networks, module.bastion.existing_networks)
    }

    networks = merge({
      (local.prefix) = {
        mtu = var.network_mtu
        subnets = {
          main = { cidr = var.web_cidr, dns_nameservers = var.dns_nameservers }
        }
        # Gateway mode: the published addresses are floating IPs of the router on publication.
        # Interface mode: the instances' own addresses, reached through the routes.
        routers = merge(local.egress ? {
          egress = { external_network = "egress", internal_subnet = "main" }
        } : {}, module.planes.routers)
      }
    }, module.bastion.networks)

    security_groups = merge({
      "${local.prefix}-https" = {
        description = local.exposed ? "Web instances: HTTPS from the public entry point only, SSH from the bastion" : "Private instances: SSH from the bastion only"
        rules       = merge(module.admission.rules, module.bastion.ssh_rules)
      }
    }, module.bastion.security_groups)

    server_groups = {
      (local.prefix) = { policy = var.server_group_policy }
    }

    load_balancers = local.load_balancer ? {
      (local.prefix) = {
        vip = { network = local.prefix, subnet = "main" }
        # The service address: on publication (a floating IP of the plane when it translates
        # addresses, the VIP itself otherwise), or a public floating IP.
        floating_ip = local.public ? { pool = "egress" } : (try(module.planes.nat["publication"], false) ? { pool = "publication" } : null)
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
        az           = local.zone_of[name]
        flavor       = var.flavor
        image        = var.image
        boot         = local.boot_in[local.zone_of[name]]
        server_group = local.prefix
        user_data    = module.cloudinit[name].rendered
        labels       = [var.name]
        ports = {
          main = {
            network         = local.prefix
            subnet          = "main"
            security_groups = ["${local.prefix}-https"]
            # A single instance is the service address (ADR-0006, D1): a floating IP of
            # publication when the plane translates addresses, a public one with exposure "public".
            floating_ip = !local.load_balancer && local.public ? { pool = "egress" } : module.planes.ports[name].floating_ip
          }
        }
      }
    }, module.bastion.instances)
  }
}
