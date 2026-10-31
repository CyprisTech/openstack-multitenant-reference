output "monitoring_targets" {
  description = "Instance exposed to the monitoring collector: its address on the monitoring plane (floating IP in gateway mode, own address in interface mode) and DNS name (or null)."
  value = {
    (local.instance) = {
      address = !module.planes.nat.monitoring ? module.isolated.instances[local.instance].ports["main"].ip : module.isolated.instances[local.instance].ports["main"].floating_ip
      fqdn    = var.monitoring.dns_zone == null ? null : "${local.instance}.${var.monitoring.dns_zone}"
    }
  }
}

output "instances" {
  description = "Isolated instance and its private address."
  value       = { (local.instance) = module.isolated.instances[local.instance].ports["main"].ip }
}

output "bastion" {
  description = "Floating IP of the bastion on the administration network, or null."
  value       = var.bastion != null ? module.isolated.instances[local.bastion_name].ports["admin"].floating_ip : null
}
