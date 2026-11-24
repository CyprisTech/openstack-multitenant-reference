# Test resolver: a small instance standing for a resolver behind a plane (ADR-0016, D3), a shared
# service of the internal services plane. Unbound answers the tenants of the plane: recursive for
# public names, through egress_network, and the zones of the landing zone forwarded to their
# servers. It stands in for the operator's resolvers, the organisation's DNS or a platform team's
# service, for a tenant without egress. It is administered through a bastion, like the stacks.

locals {
  # Boot disk of the instances: the image's ephemeral disk, or a volume of the given size.
  boot = var.boot_volume_size == null ? { source = "image" } : { source = "volume", size = var.boot_volume_size }

  name = "${var.site}-resolver"

  # Who may query: on a plane with NAT, the tenants' routers, seen at their gateway address on
  # the plane; on a plane without NAT, the ranges routed to the resolver.
  sources = module.planes.nat.internal ? [module.planes.cidr.internal] : [
    for r in var.plane_attachment.internal.routes : r.destination
  ]

  config = templatefile("${path.module}/files/unbound.conf.tftpl", {
    sources       = local.sources
    forward_zones = var.forward_zones
  })
}

module "planes" {
  source = "../../../modules/plane-attachment"

  planes         = ["internal"]
  attachment     = var.plane_attachment
  instances      = [local.name]
  exposure       = { primary = "internal" }
  default_router = "egress"
}

module "admission" {
  source = "../../../modules/admission"

  allow = {
    dns     = { ports = [53], sources = local.sources, protocol = "udp" }
    dns-tcp = { ports = [53], sources = local.sources }
  }
}

module "bastion" {
  source = "../../../modules/bastion"

  name          = "${local.name}-bastion"
  bastion       = var.bastion
  placement     = var.bastion_placement
  admin_network = "${local.name}-admin"
  default_cidr  = "10.38.0.16/28"
  network       = local.name
  port          = "resolver"
  egress        = { pool = "egress", network = var.egress_network.network }
  users         = var.users
  instance = {
    az     = var.zones[0]
    image  = var.image
    flavor = var.flavor
    boot   = local.boot
  }
  mtu             = var.network_mtu
  dns_nameservers = var.dns_nameservers
}

module "cloudinit" {
  source = "git::https://github.com/CyprisTech/terraform-openstack-tenant.git//modules/cloudinit?ref=v0.1.6"

  hostname     = local.name
  users        = { for login, keys in var.users : login => { ssh_authorized_keys = keys, sudo = true } }
  packages     = ["unbound"]
  extra_config = { apt = { conf = "Acquire::Retries \"10\";\n" } }
  write_files = {
    "/etc/unbound/unbound.conf.d/landing-zone.conf" = { content = local.config }
  }
  runcmd = [
    # systemd-resolved's stub listener holds port 53 on the loopback: Unbound answers there instead.
    "mkdir -p /etc/systemd/resolved.conf.d && printf '[Resolve]\\nDNSStubListener=no\\n' > /etc/systemd/resolved.conf.d/no-stub.conf",
    "ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf && systemctl restart systemd-resolved",
    # The package started Unbound while the stub held the port: its failures hit the start limit.
    "systemctl reset-failed unbound && systemctl restart unbound",
  ]
}

module "resolver" {
  source = "git::https://github.com/CyprisTech/terraform-openstack-tenant.git?ref=v0.1.6"

  tenant = {
    existing = {
      networks = merge({
        egress = { name = var.egress_network.network, subnets = { for k, s in { main = var.egress_network.subnet } : k => { name = s } if s != null } }
      }, module.planes.networks, module.bastion.existing_networks)
    }
    networks = merge({
      (local.name) = {
        mtu     = var.network_mtu
        subnets = { main = { cidr = var.cidr, dns_nameservers = var.dns_nameservers } }
        routers = merge({
          egress = { external_network = "egress", internal_subnet = "main" }
        }, module.planes.routers)
      }
    }, module.bastion.networks)
    security_groups = merge({
      (local.name) = {
        description = "Test resolver: DNS from the internal services plane, SSH from the bastion"
        rules       = merge(module.admission.rules, module.bastion.ssh_rules)
      }
    }, module.bastion.security_groups)
    instances = merge({
      (local.name) = {
        az        = var.zones[0], flavor = var.flavor, image = var.image
        boot      = local.boot
        user_data = module.cloudinit.rendered
        ports = {
          main = {
            network = local.name, subnet = "main", security_groups = [local.name]
            # Its address on the internal services plane: a floating IP of the plane when it
            # translates addresses, its own address otherwise.
            floating_ip = module.planes.ports[local.name].floating_ip
          }
        }
      }
    }, module.bastion.instances)
  }
}

locals {
  address = module.planes.nat.internal ? module.resolver.instances[local.name].ports["main"].floating_ip : module.resolver.instances[local.name].ports["main"].ip
}
