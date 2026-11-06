output "receiver_url" {
  description = "Base URL of the receiver, for the monitoring.receiver input of the stacks."
  value       = "http://${local.address}:9090"
}

output "address" {
  description = "Address of the receiver on its network, reached through the bastion (SSH)."
  value       = module.receiver.instances[local.name].ports["main"].ip
}

output "bastion" {
  description = "Floating IP of the bastion on the administration network."
  value       = module.receiver.instances["${local.name}-bastion"].ports["admin"].floating_ip
}
