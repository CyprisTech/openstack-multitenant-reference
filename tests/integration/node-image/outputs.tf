output "floating_ip" {
  value = module.check.instances["${local.prefix}-check"].ports.main.floating_ip
}
