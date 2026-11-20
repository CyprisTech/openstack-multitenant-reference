output "existing_networks" {
  description = "For tenant.existing.networks: the administration network, under the key admin."
  value = {
    for k in(local.own ? ["admin"] : []) : k => {
      name = var.bastion.external_network.network, subnets = { for k, s in { main = var.bastion.external_network.subnet } : k => { name = s } if s != null }
    }
  }
}

output "networks" {
  description = "For tenant.networks: the bastion's network, whose only router joins the administration network; empty with placement \"stack-network\"."
  value = {
    for k in(local.own ? local.keys : []) : var.admin_network => {
      mtu     = var.mtu
      subnets = { main = { cidr = coalesce(var.bastion.cidr, var.default_cidr), dns_nameservers = var.dns_nameservers } }
      routers = { admin = { external_network = "admin", internal_subnet = "main", default_gateway = true } }
    }
  }
}

output "security_groups" {
  description = "For tenant.security_groups: the bastion's group, SSH from bastion.ssh_cidrs."
  value = {
    for k in local.keys : k => {
      description = "Bastion: SSH from the administration sources"
      rules = {
        for i, cidr in var.bastion.ssh_cidrs : "ssh-${i}" => {
          direction = "ingress", protocol = "tcp", port_min = 22, port_max = 22, remote_ip_prefix = cidr
        }
      }
    }
  }
}

output "instances" {
  description = "For tenant.instances: the bastion, with its floating IP on the administration network (own network) or on the stack's egress router (stack network)."
  value = {
    for k in local.keys : k => {
      az           = var.instance.az
      flavor       = coalesce(var.bastion.flavor, var.instance.flavor)
      image        = var.instance.image
      boot         = var.instance.boot
      server_group = null
      user_data    = module.cloudinit[0].rendered
      labels       = ["bastion"]
      ports = merge(
        # Own network: the primary port, default route and floating IP on the administration
        # network.
        { for p in(local.own ? ["admin"] : []) : p => { network = var.admin_network, subnet = "main", security_groups = [k], floating_ip = { pool = "admin" } } },
        # The port on the stack's network: a second port without a gateway of its own (own
        # network), or the only port, with its floating IP on the egress router, which the
        # default route of the subnet reaches through the transit router (stack network).
        { (var.port) = { network = var.network, subnet = "main", security_groups = [k], floating_ip = local.own ? null : { pool = var.egress.pool } } },
      )
    }
  }
}

output "ssh_rules" {
  description = "Rules to add to the security group of the stack's instances: SSH from the bastion."
  value = {
    for k in(local.enabled ? ["ssh-from-bastion"] : []) : k => {
      direction = "ingress", protocol = "tcp", port_min = 22, port_max = 22, remote_group = var.name
    }
  }
}

output "floating_ip_port" {
  description = "Key of the bastion's port that carries its floating IP: admin (own network) or the port on the stack's network (stack network)."
  value       = local.own ? "admin" : var.port
}
