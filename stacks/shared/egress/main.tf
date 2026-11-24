# The shared egress of the landing zone (ADR-0016, D1): Squid forward proxies behind an Octavia
# load balancer, a shared service of the internal services plane. Each tenant with
# egress = "shared" reaches the Internet through it, only to the names it declares; every request
# is logged. The load balancer sends a PROXY header, so that the proxies see each tenant's source.

locals {
  # Boot disk of the instances: the image's ephemeral disk, or a volume of the given size.
  boot = var.boot_volume_size == null ? { source = "image" } : { source = "volume", size = var.boot_volume_size }

  prefix = "${var.site}-egress"

  instances = [for i in range(var.instance_count) : "${local.prefix}-${i + 1}"]
  members   = [for name in local.instances : "${name}.main"]

  bastion_name = "${local.prefix}-bastion"

  # Availability zones (ADR-0012): the instances are spread over the zones in order, the bastion
  # goes to the first.
  zone_of = { for i, name in local.instances : name => var.zones[i % length(var.zones)] }
  boot_in = { for z in var.zones : z => merge(local.boot, { az = local.boot.source == "volume" ? lookup(var.volume_zones, z, null) : null }) }

  # Who may use the proxy: every declared tenant, at its address on the internal services plane.
  sources = distinct(flatten([for t in values(var.tenants) : t.sources]))

  squid = templatefile("${path.module}/files/squid.conf.tftpl", {
    network = var.egress_cidr
    port    = var.squid_port
  })

  # The tenants (ADR-0006, D3): each one a JSON object cut into metadata items of at most 255
  # characters, updated in place on every proxy and rendered by squid-tenants; the item "tenants"
  # counts the items.
  tenant_json = { for name, t in var.tenants : name => jsonencode({ s = t.sources, d = t.domains }) }
  tenant_items = merge([
    for name, j in local.tenant_json : {
      for i in range(ceil(length(j) / 255)) : "tenant-${name}-${i}" => substr(j, i * 255, 255)
    }
  ]...)
  tenant_metadata = merge({ tenants = tostring(length(local.tenant_items)) }, local.tenant_items)
}

# The proxies admit the load balancer's amphorae, on the stack's network; the load balancer admits
# the declared tenants (allowed_cidrs).
module "admission" {
  source = "../../../modules/admission"

  allow = {
    from-lb = { ports = [var.squid_port], sources = [var.egress_cidr] }
    ssh     = { ports = [22], sources = var.admin.ssh_cidrs }
  }
}

module "bastion" {
  source = "../../../modules/bastion"

  name          = local.bastion_name
  bastion       = var.bastion
  placement     = var.bastion_placement
  admin_network = "${local.prefix}-admin"
  default_cidr  = "10.39.1.0/28"
  network       = local.prefix
  port          = "egress"
  egress        = { pool = "egress", network = var.egress_network.network }
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

# How the stack joins the planes (ADR-0004): a shared service of the internal services plane, a
# tenant of the observability plane for its metrics. The default route goes to its own egress
# router: the way out of the proxies.
module "planes" {
  source = "../../../modules/plane-attachment"

  planes         = ["internal", "observability"]
  attachment     = var.plane_attachment
  instances      = local.instances
  default_router = "egress"
}

# The metrics agent of each instance: it pushes to the receiver (ADR-0007).
module "metrics" {
  source   = "../../../modules/metrics-agent"
  for_each = toset(local.instances)

  receiver = var.monitoring.receiver
  targets  = { node = ["localhost:9100"] }
  labels   = { site = var.site, tenant = "egress", instance = each.key }
}

module "cloudinit" {
  source   = "git::https://github.com/CyprisTech/terraform-openstack-tenant.git//modules/cloudinit?ref=v0.1.6"
  for_each = toset(local.instances)

  hostname = each.key
  users = {
    for login, keys in var.admin.users : login => { ssh_authorized_keys = keys, sudo = true }
  }
  packages = concat(["squid"], module.metrics[each.key].packages)
  # A mirror error at first boot would leave the instance without its packages, silently.
  extra_config = { apt = { conf = "Acquire::Retries \"10\";\n" } }

  # Written next to the package's configuration, then put in place once Squid is installed: the
  # package does not ask about a configuration file it did not write.
  write_files = merge({
    "/etc/squid/landing-zone.conf"              = { content = local.squid }
    "/usr/local/sbin/squid-tenants"             = { content = file("${path.module}/files/squid-tenants.py"), permissions = "0755" }
    "/etc/systemd/system/squid-tenants.service" = { content = file("${path.module}/files/squid-tenants.service") }
    "/etc/systemd/system/squid-tenants.timer"   = { content = file("${path.module}/files/squid-tenants.timer") }
  }, module.metrics[each.key].write_files)

  # The tenants are rendered before Squid starts with its configuration, then every 10 seconds.
  runcmd = concat([
    "install -m 0644 /etc/squid/landing-zone.conf /etc/squid/squid.conf",
    "touch /etc/squid/tenants.conf && /usr/local/sbin/squid-tenants",
    "squid -k parse",
    "systemctl restart squid",
    "systemctl daemon-reload",
    "systemctl enable --now squid-tenants.timer",
  ], module.metrics[each.key].runcmd)
}

module "egress" {
  # Git source: works with OpenTofu and Terraform alike (registry: CyprisTech/tenant/openstack).
  source = "git::https://github.com/CyprisTech/terraform-openstack-tenant.git?ref=v0.1.6"

  tenant = {
    existing = {
      networks = merge({
        egress = { name = var.egress_network.network, subnets = { for k, s in { main = var.egress_network.subnet } : k => { name = s } if s != null } }
      }, module.planes.networks, module.bastion.existing_networks)
    }

    networks = merge({
      (local.prefix) = {
        mtu     = var.network_mtu
        subnets = { main = { cidr = var.egress_cidr, dns_nameservers = var.dns_nameservers } }
        # The egress router takes the default route of the transit router; the plane routers are
        # reached through the transit router's routes (ADR-0013).
        routers = merge({
          egress = { external_network = "egress", internal_subnet = "main" }
        }, module.planes.routers)
      }
    }, module.bastion.networks)

    security_groups = merge({
      "${local.prefix}-proxy" = {
        description = "Squid instances of the shared egress"
        rules       = merge(module.admission.rules, module.bastion.ssh_rules)
      }
    }, module.bastion.security_groups)

    server_groups = {
      (local.prefix) = { policy = var.server_group_policy }
    }

    instances = merge({
      for name in local.instances : name => {
        az           = local.zone_of[name]
        flavor       = var.flavor
        image        = var.image
        boot         = local.boot_in[local.zone_of[name]]
        server_group = local.prefix
        user_data    = module.cloudinit[name].rendered
        metadata     = local.tenant_metadata # the tenants, updated in place (ADR-0006, D3)
        labels       = ["egress", "squid"]
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
        # Its address on the internal services plane: a floating IP of the plane when it translates
        # addresses, the VIP itself otherwise.
        floating_ip = module.planes.nat.internal ? { pool = "internal" } : null
        listeners = {
          proxy = {
            protocol      = "TCP", port = var.squid_port
            allowed_cidrs = local.sources
            pool = {
              protocol = "PROXY", members = local.members
              monitor  = { type = "TCP" }
            }
          }
        }
      }
    }
  }
}

locals {
  lb      = module.egress.load_balancers[local.prefix]
  address = module.planes.nat.internal ? local.lb.floating_ip : local.lb.vip
}
