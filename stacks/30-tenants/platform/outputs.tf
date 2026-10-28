output "bootstrap" {
  description = "Floating IP of the bootstrap instance on the administration network, or null once it is removed."
  value       = var.bootstrap ? module.platform.instances[local.instance].ports["main"].floating_ip : null
}

output "edge_sources" {
  description = "Addresses of the entry point admitted by the ingress load balancer."
  value       = local.edge_sources
}

output "manifests" {
  description = "Rendered Cluster API manifests, as written on the bootstrap instance."
  value       = local.manifests
}
