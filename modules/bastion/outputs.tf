output "existing_networks" {
  description = "For tenant.existing.networks: the administration network, under the key admin."
  value = {
    for k in(local.enabled ? ["admin"] : []) : k => {
      name = var.bastion.external_network.network, subnets = { main = { name = var.bastion.external_network.subnet } }
    }
  }
}

output "networks" {
  description = "For tenant.networks: the bastion's network, whose only router joins the administration network."
  value = {
    for k in local.keys : var.admin_network => {
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
  description = "For tenant.instances: the bastion, with its floating IP on the administration network."
  value = {
    for k in local.keys : k => {
      az           = var.instance.az
      flavor       = coalesce(var.bastion.flavor, var.instance.flavor)
      image        = var.instance.image
      boot         = var.instance.boot
      server_group = null
      user_data    = module.cloudinit[0].rendered
      labels       = ["bastion"]
      ports = {
        # Primary port: default route and floating IP on the administration network.
        admin = { network = var.admin_network, subnet = "main", security_groups = [k], floating_ip = { pool = "admin" } }
        # Second port on the stack's network, without a gateway of its own.
        (var.port) = { network = var.network, subnet = "main", security_groups = [k], floating_ip = null }
      }
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
