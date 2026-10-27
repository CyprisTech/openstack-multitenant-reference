output "packer_variables" {
  description = "Variables of the image-builder OpenStack template that locate the build: read by build.sh."
  value = {
    networks            = module.build.networks[local.prefix].id
    security_groups     = local.prefix
    floating_ip_network = var.admin_network.network
  }
}
