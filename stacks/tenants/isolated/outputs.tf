
output "instances" {
  description = "Isolated instance and its private address."
  value       = { (local.instance) = module.isolated.instances[local.instance].ports["main"].ip }
}

output "bastion" {
  description = "Floating IP of the bastion on the administration network, or null."
  value       = var.bastion != null ? module.isolated.instances[local.bastion_name].ports["admin"].floating_ip : null
}
