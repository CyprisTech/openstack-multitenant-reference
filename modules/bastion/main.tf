# An administration bastion (ADR-0001, D10), written once for every stack. It creates nothing
# itself: the outputs are fragments of the tenant model of terraform-openstack-tenant, empty
# when bastion is null.

locals {
  enabled = var.bastion != null
  keys    = local.enabled ? [var.name] : []
}

module "cloudinit" {
  source = "git::https://github.com/CyprisTech/terraform-openstack-tenant.git//modules/cloudinit?ref=v0.1.3"
  count  = local.enabled ? 1 : 0

  hostname = var.name
  users = {
    for login, keys in var.users : login => { ssh_authorized_keys = keys, sudo = true }
  }

  # The second interface (on the stack's network) must not take the routes and resolvers that
  # DHCP pushes there: the bastion keeps a single default route through the administration
  # network.
  write_files = {
    "/etc/netplan/60-second-interface.yaml" = {
      permissions = "0600"
      content     = <<-EOT
        network:
          version: 2
          ethernets:
            ens4:
              dhcp4: true
              dhcp4-overrides:
                use-routes: false
                use-dns: false
      EOT
    }
  }
  runcmd = ["netplan apply"]
}
