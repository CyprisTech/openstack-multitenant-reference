# A shared service on virtual machines (spec docs/specs/shared-vm.md): the contract of the shared
# cluster around a workload the adopter brings. The stack joins the internal services plane with
# role shared, gives each service one address there (ADR-0006, D1), admits the consumers on its
# ports and nobody else, writes the names of the services (ADR-0016, D2), and gives the instances a
# certificate from an ACME directory (ADR-0008) and the metrics agent (ADR-0007). Running the
# workload (its backups, its replication, its upgrades) is the service's (ADR-0010, D4).

locals {
  prefix = "${var.site}-${var.name}"

  instances = [for i in range(var.instance_count) : "${local.prefix}-${i + 1}"]

  # Boot disk of the instances: the image's ephemeral disk, or a volume of the given size.
  boot = var.boot_volume_size == null ? { source = "image" } : { source = "volume", size = var.boot_volume_size }

  # Availability zones (ADR-0012): the instances are spread over the zones in order, the bastion
  # goes to the first. A root volume takes the storage zone mapped to the instance's zone.
  zone_of = { for i, name in local.instances : name => var.zones[i % length(var.zones)] }
  boot_in = { for z in var.zones : z => merge(local.boot, { az = local.boot.source == "volume" ? lookup(var.volume_zones, z, null) : null }) }

  router = var.egress == "router"
  shared = var.egress == "shared"
  egress = var.egress != "none"

  # One address per service: a load balancer in front of the instances when there are several.
  load_balancer = var.instance_count > 1
  nat           = module.planes.nat.internal

  # Who may connect to each service, and the ports the instances serve.
  sources = { for k, s in var.services : k => s.sources == null ? var.consumers : s.sources }
  # Behind a load balancer the instances are reached from its amphorae, on the service's network;
  # the listeners admit the sources.
  instance_sources = { for k, s in local.sources : k => local.load_balancer ? [var.cidr] : s }

  domains = distinct(flatten([for s in var.services : s.domains]))
  san     = join(",", [for d in local.domains : "DNS:${d}"])

  # Certificates (ADR-0008): obtained by the ACME client, or self-signed in demonstration mode
  # when the services have names.
  acme       = var.certificates != null
  selfsigned = !local.acme && length(local.domains) > 0
  demo       = var.workload == null
  reload     = var.tls_reload != null ? [var.tls_reload] : local.demo ? ["systemctl enable demo-service.service", "systemctl restart demo-service.service"] : []

  bastion_name = "${local.prefix}-bastion"
}

# Demonstration mode: a warning at every plan and apply, without failing.
check "certificates" {
  assert {
    condition     = var.certificates != null || length(local.domains) == 0
    error_message = "certificates not set: self-signed certificate, for evaluation only (ADR-0008)."
  }
}

module "admission" {
  source = "../../../modules/admission"

  allow = merge(
    { for k, s in var.services : "service-${k}" => { ports = s.ports, sources = local.instance_sources[k] } if length(local.instance_sources[k]) > 0 },
    { ssh = { ports = [22], sources = var.admin.ssh_cidrs } },
  )
}

module "bastion" {
  source = "../../../modules/bastion"

  name          = local.bastion_name
  bastion       = var.bastion
  placement     = var.bastion_placement
  admin_network = "${local.prefix}-admin"
  default_cidr  = "10.31.0.0/28"
  network       = local.prefix
  port          = "main"
  egress        = local.router ? { pool = "egress", network = var.egress_network.network } : null
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

# How the stack joins the planes (ADR-0004): the internal services plane, with role shared, and the
# observability plane when the attachment has it.
module "planes" {
  source = "../../../modules/plane-attachment"

  planes         = concat(["internal"], contains(keys(var.plane_attachment), "observability") ? ["observability"] : [])
  attachment     = var.plane_attachment
  default_router = local.router ? "egress" : null
  instances      = local.instances
  exposure = {
    # A single instance is the address of the services; behind load balancers, instances have none.
    primary = local.load_balancer ? null : "internal"
  }
}

# The ACME client of the instances (ADR-0008): lego, installing the certificate for the workload.
module "acme" {
  source = "../../../modules/acme-client"

  certificates     = var.certificates
  domains          = local.domains
  lego_version     = var.lego_version
  certificate_path = "/etc/shared-service/tls/cert.pem"
  key_path         = "/etc/shared-service/tls/key.pem"
  deploy_commands  = local.reload
}

# The metrics agent of each instance: it pushes to the receiver through the observability plane
# (ADR-0007), when the service joins it. Its packages need the egress.
module "metrics" {
  source   = "../../../modules/metrics-agent"
  for_each = toset(local.egress && contains(keys(var.plane_attachment), "observability") && var.monitoring.receiver != null ? local.instances : [])

  receiver = var.monitoring.receiver
  labels   = { site = var.site, service = var.name, instance = each.key }
}

# The shared egress (ADR-0016, D1): no route to the Internet, a proxy on the internal services
# plane, for apt, the shells and the system services; the planes and the service's network are in
# NO_PROXY.
locals {
  no_proxy = join(",", concat(["localhost", "127.0.0.1", "169.254.169.254", var.cidr], [for p in values(var.plane_attachment) : p.cidr]))
  proxy_files = local.shared ? {
    "/etc/systemd/system.conf.d/proxy.conf" = {
      content = "[Manager]\nDefaultEnvironment=\"HTTP_PROXY=${var.shared_egress.proxy}\" \"HTTPS_PROXY=${var.shared_egress.proxy}\" \"http_proxy=${var.shared_egress.proxy}\" \"https_proxy=${var.shared_egress.proxy}\" \"NO_PROXY=${local.no_proxy}\" \"no_proxy=${local.no_proxy}\"\n"
    }
    "/etc/profile.d/proxy.sh" = {
      content = "export HTTP_PROXY=${var.shared_egress.proxy} HTTPS_PROXY=${var.shared_egress.proxy} http_proxy=${var.shared_egress.proxy} https_proxy=${var.shared_egress.proxy} NO_PROXY=${local.no_proxy} no_proxy=${local.no_proxy}\n"
    }
  } : {}
  apt_proxy = local.shared ? "Acquire::http::Proxy \"${var.shared_egress.proxy}\";\nAcquire::https::Proxy \"${var.shared_egress.proxy}\";\n" : ""
  # The proxy admits the service once it is declared there: at first boot, before the packages,
  # the instance waits for it (up to 30 minutes).
  proxy_hostport = local.shared ? regex("^https?://([^/:]+):([0-9]+)", var.shared_egress.proxy) : []
  proxy_wait = local.shared ? [
    "bash -c 'for i in $(seq 180); do timeout 3 bash -c \"</dev/tcp/${local.proxy_hostport[0]}/${local.proxy_hostport[1]}\" 2>/dev/null && exit 0; sleep 10; done; echo shared egress not reached >&2'",
  ] : []

  # The demonstration workload, on the ports of the services.
  demo_ports = { for p in flatten([for k, s in var.services : [for port in s.ports : { port = tostring(port), service = k }]]) : p.port => p.service }
  workload = local.demo ? {
    packages = []
    write_files = {
      for name in local.instances : name => {
        "/usr/local/bin/demo-service" = {
          content     = templatefile("${path.module}/files/demo-service.py.tftpl", { ports = local.demo_ports, instance = name })
          permissions = "0755"
        }
        "/etc/systemd/system/demo-service.service" = { content = file("${path.module}/files/demo-service.service") }
      }
    }
    # With certificates, the deploy hook starts it once the certificate is issued.
    runcmd = local.acme ? ["systemctl daemon-reload"] : ["systemctl daemon-reload", "systemctl enable --now demo-service.service"]
    } : {
    packages    = var.workload.packages
    write_files = { for name in local.instances : name => var.workload.write_files }
    runcmd      = var.workload.runcmd
  }
}

module "cloudinit" {
  source   = "git::https://github.com/CyprisTech/terraform-openstack-tenant.git//modules/cloudinit?ref=v0.1.6"
  for_each = toset(local.instances)

  hostname       = each.key
  package_update = local.egress
  users = {
    for login, keys in var.admin.users : login => { ssh_authorized_keys = keys, sudo = true }
  }
  packages = local.egress ? concat(local.workload.packages, try(module.metrics[each.key].packages, [])) : []

  write_files = merge(
    local.workload.write_files[each.key],
    module.acme.write_files,
    try(module.metrics[each.key].write_files, {}),
    local.proxy_files,
  )

  # Demonstration mode: the self-signed certificate exists before the workload starts; bootcmd runs
  # before package installation (and at every boot, hence the test). apt retries: a mirror error at
  # first boot would leave the instance without its packages, silently.
  extra_config = {
    apt = { conf = "Acquire::Retries \"10\";\n${local.apt_proxy}" }
    bootcmd = concat(local.proxy_wait, ["mkdir -p -m 0700 /etc/shared-service/tls"], local.selfsigned ? [
      "test -f /etc/shared-service/tls/cert.pem || openssl req -x509 -newkey rsa:2048 -nodes -days 90 -subj /CN=${local.domains[0]} -addext subjectAltName=${local.san} -keyout /etc/shared-service/tls/key.pem -out /etc/shared-service/tls/cert.pem",
    ] : [])
  }

  runcmd = concat(local.workload.runcmd, module.acme.runcmd, try(module.metrics[each.key].runcmd, []))
}

module "service" {
  source = "git::https://github.com/CyprisTech/terraform-openstack-tenant.git?ref=v0.1.6"

  tenant = {
    existing = {
      networks = merge(local.router ? {
        egress = { name = var.egress_network.network, subnets = { for k, s in { main = var.egress_network.subnet } : k => { name = s } if s != null } }
      } : {}, module.planes.networks, module.bastion.existing_networks)
    }

    networks = merge({
      (local.prefix) = {
        mtu = var.network_mtu
        subnets = {
          main = { cidr = var.cidr, dns_nameservers = var.dns_nameservers }
        }
        routers = merge(local.router ? {
          egress = { external_network = "egress", internal_subnet = "main" }
        } : {}, module.planes.routers)
      }
    }, module.bastion.networks)

    security_groups = merge({
      (local.prefix) = {
        description = "Shared service: its ports from the consumers only, SSH from the bastion"
        rules       = merge(module.admission.rules, module.bastion.ssh_rules)
      }
    }, module.bastion.security_groups)

    server_groups = {
      (local.prefix) = { policy = var.server_group_policy }
    }

    # One internal load balancer per service: its address on the internal services plane (a
    # floating IP of the plane when it translates addresses, the VIP otherwise). The service
    # terminates TLS: the listeners pass TCP through (ADR-0008, D5).
    load_balancers = local.load_balancer ? {
      for k, s in var.services : "${local.prefix}-${k}" => {
        vip         = { network = local.prefix, subnet = "main" }
        floating_ip = local.nat ? { pool = "internal" } : null
        listeners = {
          for port in s.ports : "tcp-${port}" => {
            protocol = "TCP", port = port
            # No source: closed. Octavia admits every source when allowed_cidrs is empty, so a
            # listener without consumers admits only the service's own network.
            allowed_cidrs = length(local.sources[k]) > 0 ? local.sources[k] : [var.cidr]
            pool = {
              protocol = "TCP"
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
            security_groups = [local.prefix]
            floating_ip     = module.planes.ports[name].floating_ip
          }
        }
      }
    }, module.bastion.instances)
  }
}

# The names of the services, in the zone of the internal names, when the cloud has Designate and
# the zone is owned by or shared with this project: dns = "designate". With dns = "output", none is
# written; the dns_records output gives them in both cases (ADR-0016, D2).
module "names" {
  count  = var.internal_zone != null && var.dns == "designate" ? 1 : 0
  source = "git::https://github.com/CyprisTech/terraform-openstack-tenant.git//modules/dns?ref=v0.1.6"

  records = { for k, r in local.records : k => merge(r, { zone_id = var.internal_zone.id, zone_name = var.internal_zone.name }) }
}

locals {
  # The address of each service on the internal services plane.
  addresses = {
    for k, s in var.services : k => local.load_balancer ? (
      local.nat ? module.service.load_balancers["${local.prefix}-${k}"].floating_ip : module.service.load_balancers["${local.prefix}-${k}"].vip
      ) : (
      local.nat ? module.service.instances[local.instances[0]].ports["main"].floating_ip : module.service.instances[local.instances[0]].ports["main"].ip
    )
  }

  records = var.internal_zone == null ? {} : merge([
    for k, s in var.services : {
      for d in s.domains : d => {
        name    = trimsuffix(d, ".${trimsuffix(var.internal_zone.name, ".")}")
        type    = "A"
        records = [local.addresses[k]]
        ttl     = var.internal_zone.ttl
      }
    }
  ]...)
}
