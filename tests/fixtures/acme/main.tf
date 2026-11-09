# Test ACME authority (ADR-0008): a small instance standing for the organisation's DNS and
# certificate authority, a shared service of the internal services plane.
# - Knot, authoritative for the test zone, accepts RFC 2136 updates signed with one TSIG key
#   per tenant, each allowed to change only the TXT records _acme-challenge.<its names>.
# - step-ca serves an ACME directory and validates DNS-01 challenges against Knot.
# The root certificate is generated here, so that the stacks receive it as ca_bundle: its key
# is in the state of this fixture and, with the TSIG keys, in the instance's user data, readable
# by the members of the project. Acceptable for a test authority in its own project only.
# The instance gets its packages through egress_network and is administered through a bastion.

locals {
  name = "${var.site}-acme"
  zone = trimsuffix(var.zone, ".")

  # Boot disk of the instances: the image's ephemeral disk, or a volume of the given size.
  boot = var.boot_volume_size == null ? { source = "image" } : { source = "volume", size = var.boot_volume_size }

  # Who may query and update the DNS and use the ACME directory: on a plane with NAT, the tenants'
  # routers, seen at their gateway address on the plane; on a plane without NAT, the ranges routed
  # to the authority.
  sources = module.planes.nat.internal ? [module.planes.cidr.internal] : [
    for r in var.plane_attachment.internal.routes : r.destination
  ]

  # Knot: one TSIG key per tenant, allowed to update only the TXT records _acme-challenge.<its names>.
  knot_conf = templatefile("${path.module}/files/knot.conf.tftpl", {
    tenants = var.tenants
    tsig    = { for t in keys(var.tenants) : t => random_bytes.tsig[t].base64 }
    sources = local.sources
    zone    = local.zone
  })

  # step-ca: the root comes from this stack; the intermediate and the ACME provisioner are created
  # at first boot. The server certificate must name the address the tenants use: on a plane with
  # NAT, the floating IP, read from the metadata service once it is associated.
  step_init = templatefile("${path.module}/files/step-ca-init.sh.tftpl", { nat = module.planes.nat.internal })
}

resource "random_bytes" "tsig" {
  for_each = var.tenants
  length   = 32
}

resource "tls_private_key" "root" {
  algorithm   = "ECDSA"
  ecdsa_curve = "P256"
}

resource "tls_self_signed_cert" "root" {
  private_key_pem = tls_private_key.root.private_key_pem
  subject { common_name = "Test ACME authority root" }
  is_ca_certificate     = true
  validity_period_hours = 24 * 365
  allowed_uses          = ["cert_signing", "crl_signing"]
}

module "planes" {
  source = "../../../modules/plane-attachment"

  planes     = ["internal"]
  attachment = var.plane_attachment
  instances  = [local.name]
  exposure   = { primary = "internal" }
}

module "admission" {
  source = "../../../modules/admission"

  allow = {
    dns     = { ports = [53], sources = local.sources }
    dns-udp = { ports = [53], sources = local.sources, protocol = "udp" }
    acme    = { ports = [443], sources = local.sources }
  }
}

module "bastion" {
  source = "../../../modules/bastion"

  name          = "${local.name}-bastion"
  bastion       = var.bastion
  admin_network = "${local.name}-admin"
  default_cidr  = "10.38.0.0/28"
  network       = local.name
  port          = "authority"
  users         = var.users
  instance = {
    az     = var.az
    image  = var.image
    flavor = var.flavor
    boot   = local.boot
  }
  mtu             = var.network_mtu
  dns_nameservers = var.dns_nameservers
}

module "cloudinit" {
  source = "git::https://github.com/CyprisTech/terraform-openstack-tenant.git//modules/cloudinit?ref=v0.1.5"

  hostname     = local.name
  users        = { for login, keys in var.users : login => { ssh_authorized_keys = keys, sudo = true } }
  packages     = ["knot", "jq"]
  extra_config = { apt = { conf = "Acquire::Retries \"10\";\n" } }
  write_files = {
    "/etc/knot/knot.conf"                 = { content = local.knot_conf, permissions = "0640" }
    "/var/lib/knot/${local.zone}.zone"    = { content = templatefile("${path.module}/files/zone.tftpl", { zone = local.zone }) }
    "/etc/step-ca-root/root.crt"          = { content = tls_self_signed_cert.root.cert_pem }
    "/etc/step-ca-root/root.key"          = { content = tls_private_key.root.private_key_pem, permissions = "0600" }
    "/usr/local/sbin/step-ca-init"        = { content = local.step_init, permissions = "0755" }
    "/etc/systemd/system/step-ca.service" = { content = file("${path.module}/files/step-ca.service") }
  }
  runcmd = [
    # systemd-resolved's stub listener holds port 53 on the loopback: Knot answers there instead.
    "mkdir -p /etc/systemd/resolved.conf.d && printf '[Resolve]\\nDNSStubListener=no\\n' > /etc/systemd/resolved.conf.d/no-stub.conf",
    "ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf && systemctl restart systemd-resolved",
    "chown -R knot:knot /var/lib/knot && chgrp knot /etc/knot/knot.conf",
    "systemctl restart knot",
    "curl -fsSLo /tmp/step-cli.deb https://github.com/smallstep/cli/releases/download/v${var.step_version.cli}/step-cli_${var.step_version.cli}-1_amd64.deb",
    "curl -fsSLo /tmp/step-ca.deb https://github.com/smallstep/certificates/releases/download/v${var.step_version.ca}/step-ca_${var.step_version.ca}-1_amd64.deb",
    "apt-get install -y /tmp/step-cli.deb /tmp/step-ca.deb",
    "systemctl daemon-reload",
    "systemctl enable --now step-ca.service",
  ]
}

module "authority" {
  source = "git::https://github.com/CyprisTech/terraform-openstack-tenant.git?ref=v0.1.5"

  tenant = {
    existing = {
      networks = merge({
        egress = { name = var.egress_network.network, subnets = { main = { name = var.egress_network.subnet } } }
      }, module.planes.networks, module.bastion.existing_networks)
    }
    networks = merge({
      (local.name) = {
        mtu     = var.network_mtu
        subnets = { main = { cidr = var.cidr, dns_nameservers = var.dns_nameservers } }
        routers = merge({
          egress = { external_network = "egress", internal_subnet = "main", default_gateway = true }
        }, module.planes.routers)
      }
    }, module.bastion.networks)
    security_groups = merge({
      (local.name) = {
        description = "Test ACME authority: DNS and ACME from the internal services plane, SSH from the bastion"
        rules       = merge(module.admission.rules, module.bastion.ssh_rules)
      }
    }, module.bastion.security_groups)
    instances = merge({
      (local.name) = {
        az        = var.az, flavor = var.flavor, image = var.image
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
  address = module.planes.nat.internal ? module.authority.instances[local.name].ports["main"].floating_ip : module.authority.instances[local.name].ports["main"].ip
}

