output "proxy" {
  description = "URL of the shared egress on the internal services plane, for the shared_egress input of the tenants with egress = \"shared\": a floating IP of the plane with NAT, the load balancer's address otherwise."
  value       = "http://${local.address}:${var.squid_port}"
}

output "tenants" {
  description = "The tenants admitted, with their sources and the names they may reach."
  value       = var.tenants
}

output "instances" {
  description = "The proxy instances and their addresses on the stack's network, reached through the bastion (SSH): the access log of each is /var/log/squid/access.log."
  value       = { for name in local.instances : name => module.egress.instances[name].ports["main"].ip }
}

output "bastion" {
  description = "Floating IP of the bastion on the administration network, or null."
  value       = var.bastion != null ? module.egress.instances[local.bastion_name].ports[module.bastion.floating_ip_port].floating_ip : null
}
