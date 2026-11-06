# Test receiver: a small instance standing for the metrics receiver, a shared service of the
# observability plane (ADR-0007). Prometheus with its remote-write and OTLP receivers: the tenants
# push to the receiver_url output; nothing connects into the tenants. It is administered through
# a bastion, like the stacks, and gets packages and its image through egress_network.

locals {
  # Boot disk of the instances: the image's ephemeral disk, or a volume of the given size.
  boot = var.boot_volume_size == null ? { source = "image" } : { source = "volume", size = var.boot_volume_size }

  name = "${var.site}-receiver"

  # Who may push: on a plane with NAT, the tenants' routers, seen at their gateway address on
  # the plane; on a plane without NAT, the ranges routed to the receiver.
  push_sources = module.planes.nat.observability ? [module.planes.cidr.observability] : [
    for r in var.plane_attachment.observability.routes : r.destination
  ]

  config = yamlencode({
    global = { scrape_interval = "30s" }
    # OTLP resources: their site and tenant become labels, like the external labels of the agents.
    otlp           = { promote_resource_attributes = ["site", "tenant"] }
    scrape_configs = [{ job_name = "receiver", static_configs = [{ targets = ["localhost:9090"] }] }]
  })

  unit = templatefile("${path.module}/files/prometheus.service.tftpl", { image = var.prometheus_image })
}

module "planes" {
  source = "../../../modules/plane-attachment"

  planes     = ["observability"]
  attachment = var.plane_attachment
  instances  = [local.name]
  exposure   = { primary = "observability" }
}

module "admission" {
  source = "../../../modules/admission"

  allow = {
    push = { ports = [9090], sources = local.push_sources }
  }
}

module "bastion" {
  source = "../../../modules/bastion"

  name          = "${local.name}-bastion"
  bastion       = var.bastion
  admin_network = "${local.name}-admin"
  default_cidr  = "10.36.0.0/28"
  network       = local.name
  port          = "receiver"
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
  source = "git::https://github.com/CyprisTech/terraform-openstack-tenant.git//modules/cloudinit?ref=v0.1.4"

  hostname     = local.name
  users        = { for login, keys in var.users : login => { ssh_authorized_keys = keys, sudo = true } }
  packages     = ["podman"]
  extra_config = { apt = { conf = "Acquire::Retries \"10\";\n" } }
  write_files = {
    "/etc/prometheus/prometheus.yml"         = { content = local.config }
    "/etc/systemd/system/prometheus.service" = { content = local.unit }
  }
  runcmd = ["systemctl daemon-reload", "systemctl enable --now prometheus.service"]
}

module "receiver" {
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
        description = "Test receiver: pushes from the observability plane, SSH from the bastion"
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
            # Its address on the observability plane: a floating IP of the plane when it translates
            # addresses, its own address otherwise.
            floating_ip = module.planes.ports[local.name].floating_ip
          }
        }
      }
    }, module.bastion.instances)
  }
}

locals {
  address = module.planes.nat.observability ? module.receiver.instances[local.name].ports["main"].floating_ip : module.receiver.instances[local.name].ports["main"].ip
}

