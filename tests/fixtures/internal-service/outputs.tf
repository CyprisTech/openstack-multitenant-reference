output "address" {
  description = "Address of the service on the internal services plane (port 8080): its floating IP on a plane with NAT (which also carries SSH), its own address on a plane without NAT."
  value       = module.planes.nat.internal ? module.service.instances[local.name].ports["main"].floating_ip : module.service.instances[local.name].ports["main"].ip
}

output "service_sources" {
  description = "Sources admitted on port 8080."
  value       = var.allowed_sources
}
