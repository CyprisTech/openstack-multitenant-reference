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

output "scripts" {
  description = "Rendered create and delete scripts, as written on the bootstrap instance (cloud-init writes them once: copy them again after a change)."
  value       = local.scripts
}

output "routes" {
  description = "Routes for the entry point (stack 20, variable routes): the platform domains to the ingress floating IP on svc_public."
  value       = { for d in var.cluster.domains : d => { backends = ["${openstack_networking_floatingip_v2.ingress.address}:443"] } }
}

output "prometheus" {
  description = "Federation endpoint of the in-cluster Prometheus on the monitoring plane, or null when it is not exposed."
  value = local.expose_prometheus ? {
    address = openstack_networking_floatingip_v2.prometheus[0].address
    port    = 9090
    fqdn    = local.prometheus_record ? "${local.prefix}-prometheus.${var.monitoring.dns_zone}" : null
  } : null
}
