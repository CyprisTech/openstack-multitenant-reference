# Test ACME authority (ADR-0008): a small instance standing for the organisation's DNS and
# certificate authority, a shared service of the internal services plane.
# - Knot, authoritative for the test zone, accepts RFC 2136 updates signed with one TSIG key
#   per tenant, each allowed to change only the TXT records _acme-challenge.<its names>.
# - step-ca serves an ACME directory and validates DNS-01 challenges against Knot.
# The root certificate is generated here, so that the stacks receive it as ca_bundle: its key
# is in the state of this fixture and, with the TSIG keys, in the instance's user data, readable
# by the members of the project. Acceptable for a test authority in its own project only.
# The instance gets its packages through egress_network and is administered through a bastion.

terraform {
  required_version = ">= 1.9"
  required_providers {
    openstack = { source = "terraform-provider-openstack/openstack", version = "~> 3.2" }
    random    = { source = "hashicorp/random", version = "~> 3.6" }
    tls       = { source = "hashicorp/tls", version = "~> 4.0" }
  }
}

provider "openstack" {
  cloud = var.cloud
}

variable "cloud" { type = string }
variable "site" { type = string }
variable "az" { type = string }
variable "image" { type = string }
variable "flavor" { type = string }
variable "boot_volume_size" {
  type    = number
  default = null
}
variable "network_mtu" {
  type    = number
  default = null
}
variable "dns_nameservers" {
  type    = list(string)
  default = []
}
variable "plane_attachment" {
  description = "The service's entry of the attachments output of stack shared/planes (role shared on intranet)."
  type = map(object({
    mode         = string
    nat          = bool
    cidr         = string
    network_id   = string
    network_name = string
    subnet_id    = string
    routes       = optional(list(object({ destination = string, next_hop = string })), [])
  }))
}
variable "cidr" {
  description = "Range of the authority's network; on an interface plane, the attachment's cidr in shared/planes."
  type        = string
  default     = "10.37.0.0/28"
}
variable "egress_network" {
  description = "External network giving the default route (package download)."
  type        = object({ network = string, subnet = string })
}
variable "bastion" {
  description = "Administration bastion: floating IP on external_network, SSH from ssh_cidrs."
  type = object({
    external_network = object({ network = string, subnet = string })
    ssh_cidrs        = list(string)
  })
}
variable "users" {
  description = "SSH users (login => public keys, sudo granted), on the bastion and the authority."
  type        = map(list(string))
}
variable "zone" {
  description = "The test zone served by Knot; the tenants' names are under it."
  type        = string
  default     = "example.org"
}
variable "tenants" {
  description = <<-EOT
    The tenants that obtain certificates, keyed by tenant name, with the names (domains) each may
    get a certificate for. Each tenant gets its own TSIG key, allowed to update only the TXT
    records _acme-challenge.<name> of its names.
  EOT
  type        = map(list(string))
  validation {
    condition = alltrue(flatten([for names in values(var.tenants) : [
      for n in names : n == var.zone || endswith(n, ".${var.zone}")
    ]]))
    error_message = "Every name must be in the test zone."
  }
}
variable "step_version" {
  description = "Versions of step-ca and step-cli (Debian packages of the smallstep releases), pinned."
  type        = object({ ca = string, cli = string })
  default     = { ca = "0.30.2", cli = "0.31.0" }
}

locals {
  name = "${var.site}-acme"
  zone = trimsuffix(var.zone, ".")

  # Who may query and update the DNS and use the ACME directory: on a plane with NAT, the tenants'
  # routers, seen at their gateway address on the plane; on an interface plane, the ranges routed
  # to the authority.
  sources = module.planes.nat.intranet ? [module.planes.cidr.intranet] : [
    for r in var.plane_attachment.intranet.routes : r.destination
  ]

  # Written without indentation: the template directives would defeat the stripping of <<-EOT.
  knot_conf = <<EOT
server:
  listen: [0.0.0.0@53]
log:
  - target: syslog
    any: info
key:
%{for t in keys(var.tenants)~}
  - id: ${t}
    algorithm: hmac-sha256
    secret: ${random_bytes.tsig[t].base64}
%{endfor~}
acl:
%{for t, names in var.tenants~}
  - id: ${t}
    key: ${t}
    address: [${join(", ", local.sources)}]
    action: update
    update-type: [TXT]
    update-owner: name
    update-owner-match: equal
    update-owner-name: [${join(", ", [for n in names : "_acme-challenge.${n}."])}]
%{endfor~}
template:
  - id: default
    storage: /var/lib/knot
    zonefile-sync: -1
    zonefile-load: difference-no-serial
    journal-content: all
zone:
  - domain: ${local.zone}
    acl: [${join(", ", keys(var.tenants))}]
EOT

  zone_file = <<-EOT
    $ORIGIN ${local.zone}.
    $TTL 60
    @   SOA ns admin 1 3600 900 604800 60
    @   NS  ns
  EOT

  # step-ca: the root comes from this stack; the intermediate and the ACME provisioner are created
  # at first boot. The server certificate must name the address the tenants use: on a plane with
  # NAT, the floating IP, read from the metadata service once it is associated.
  step_init = <<-EOT
    #!/bin/bash
    set -euo pipefail
    export STEPPATH=/etc/step-ca
    [ -f "$STEPPATH/config/ca.json" ] && exit 0
    own=$(curl -fsS http://169.254.169.254/latest/meta-data/local-ipv4)
    names="$own"
    if [ "${module.planes.nat.intranet}" = "true" ]; then
      for _ in $(seq 60); do
        fip=$(curl -fsS http://169.254.169.254/latest/meta-data/public-ipv4 || true)
        [ -n "$fip" ] && break
        sleep 5
      done
      [ -n "$fip" ] && names="$names,$fip"
    fi
    head -c 32 /dev/urandom | base64 > /etc/step-ca-password
    chmod 600 /etc/step-ca-password
    step ca init --deployment-type standalone --name "Test ACME authority" \
      --dns "$names" --address :443 --provisioner admin --acme \
      --root /etc/step-ca-root/root.crt --key /etc/step-ca-root/root.key \
      --password-file /etc/step-ca-password --provisioner-password-file /etc/step-ca-password
    # Certificates valid 90 days, like Let's Encrypt, so that renewal 30 days before expiry is exercised.
    jq '(.authority.provisioners[] | select(.type == "ACME") | .claims) = {"defaultTLSCertDuration": "2160h", "maxTLSCertDuration": "2160h"}' \
      "$STEPPATH/config/ca.json" > /tmp/ca.json && mv /tmp/ca.json "$STEPPATH/config/ca.json"
    chmod -R go-rwx "$STEPPATH" /etc/step-ca-root
  EOT

  step_unit = <<-EOT
    [Unit]
    Description=step-ca (test ACME authority)
    Wants=network-online.target knot.service
    After=network-online.target knot.service

    [Service]
    Environment=STEPPATH=/etc/step-ca
    ExecStartPre=/usr/local/sbin/step-ca-init
    ExecStart=/usr/bin/step-ca /etc/step-ca/config/ca.json --password-file /etc/step-ca-password --resolver 127.0.0.1:53
    Restart=always
    RestartSec=5

    [Install]
    WantedBy=multi-user.target
  EOT
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

  planes     = ["intranet"]
  attachment = var.plane_attachment
  instances  = [local.name]
  exposure   = { primary = "intranet" }
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
    boot   = var.boot_volume_size == null ? { source = "image" } : { source = "volume", size = var.boot_volume_size }
  }
  mtu             = var.network_mtu
  dns_nameservers = var.dns_nameservers
}

module "cloudinit" {
  source = "git::https://github.com/CyprisTech/terraform-openstack-tenant.git//modules/cloudinit?ref=v0.1.4"

  hostname     = local.name
  users        = { for login, keys in var.users : login => { ssh_authorized_keys = keys, sudo = true } }
  packages     = ["knot", "jq"]
  extra_config = { apt = { conf = "Acquire::Retries \"10\";\n" } }
  write_files = {
    "/etc/knot/knot.conf"                 = { content = local.knot_conf, permissions = "0640" }
    "/var/lib/knot/${local.zone}.zone"    = { content = local.zone_file }
    "/etc/step-ca-root/root.crt"          = { content = tls_self_signed_cert.root.cert_pem }
    "/etc/step-ca-root/root.key"          = { content = tls_private_key.root.private_key_pem, permissions = "0600" }
    "/usr/local/sbin/step-ca-init"        = { content = local.step_init, permissions = "0755" }
    "/etc/systemd/system/step-ca.service" = { content = local.step_unit }
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
  source = "git::https://github.com/CyprisTech/terraform-openstack-tenant.git?ref=v0.1.4"

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
        boot      = var.boot_volume_size == null ? { source = "image" } : { source = "volume", size = var.boot_volume_size }
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
  address = module.planes.nat.intranet ? module.authority.instances[local.name].ports["main"].floating_ip : module.authority.instances[local.name].ports["main"].ip
}

output "certificates" {
  description = "The certificates input of each tenant stack, keyed by tenant: ACME directory, root, DNS-01 through RFC 2136 with the tenant's TSIG key."
  sensitive   = true
  value = {
    for t in keys(var.tenants) : t => {
      directory_url = "https://${local.address}/acme/acme/directory"
      ca_bundle     = tls_self_signed_cert.root.cert_pem
      email         = "admin@${local.zone}"
      dns = {
        provider = "rfc2136"
        settings = {
          nameserver     = "${local.address}:53"
          tsig_key_name  = t
          tsig_algorithm = "hmac-sha256"
          tsig_secret    = random_bytes.tsig[t].base64
        }
        # The test zone is not in the public DNS: lego checks the TXT record on Knot directly.
        resolvers = ["${local.address}:53"]
      }
    }
  }
}

output "root_certificate" {
  description = "Root certificate of the test authority, for the clients of the tests."
  value       = tls_self_signed_cert.root.cert_pem
}

output "address" {
  description = "Address of the authority on the internal services plane (DNS on 53, ACME on 443)."
  value       = local.address
}

output "bastion" {
  description = "Floating IP of the bastion on the administration network."
  value       = module.authority.instances["${local.name}-bastion"].ports["admin"].floating_ip
}

output "zone" {
  description = "The test zone."
  value       = local.zone
}

output "tenants" {
  description = "Names each tenant may obtain certificates for."
  value       = var.tenants
}

output "instance_address" {
  description = "Address of the authority on its own network, reached through the bastion (SSH)."
  value       = module.authority.instances[local.name].ports["main"].ip
}
