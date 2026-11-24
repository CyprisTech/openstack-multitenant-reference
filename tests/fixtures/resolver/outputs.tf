output "resolver" {
  description = "Address of the resolver on the internal services plane (port 53), for the dns_nameservers input of a tenant that joins the plane."
  value       = local.address
}

output "sources" {
  description = "Sources admitted on port 53."
  value       = local.sources
}

output "address" {
  description = "Address of the resolver on its network, reached through the bastion (SSH)."
  value       = module.resolver.instances[local.name].ports["main"].ip
}

output "bastion" {
  description = "Floating IP of the bastion on the administration network."
  value       = module.resolver.instances["${local.name}-bastion"].ports[module.bastion.floating_ip_port].floating_ip
}
