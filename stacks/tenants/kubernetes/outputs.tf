output "bootstrap" {
  description = "Floating IP of the bootstrap instance on the administration network, or null once it is removed."
  value       = var.bootstrap ? module.platform.instances[local.instance].ports["main"].floating_ip : null
}

output "edge_sources" {
  description = "Addresses of the entry point admitted by the ingress load balancer."
  value       = var.edge_sources
}

output "intranet_sources" {
  description = "Addresses the cluster reaches the intranet from, for the services of the intranet (allowed_sources): its router's gateway address on an operator plane, the cluster range on an interface plane."
  value = module.planes.nat.intranet ? [
    for ip in data.openstack_networking_router_v2.intranet[0].external_fixed_ip : "${ip.ip_address}/32"
  ] : [var.cluster_cidr]
}

output "manifests" {
  description = "Rendered Cluster API manifests, as written on the bootstrap instance."
  value       = local.manifests
}

output "scripts" {
  description = "Rendered create and delete scripts, as written on the bootstrap instance (cloud-init writes them once: copy them again after a change)."
  value       = local.scripts
}

output "published_domains" {
  description = "Domains served by this tenant and their backends, for the domains input of the entry point (scripts/publish-domains.sh): the platform domains to the ingress (floating IP on svc_public in gateway mode, load balancer address in interface mode)."
  value       = { for d in var.cluster.domains : d => { backends = ["${local.ingress_address}:443"] } }
}

output "prometheus" {
  description = "Federation endpoint of the in-cluster Prometheus on the monitoring plane, or null when it is not exposed."
  value = local.expose_prometheus ? {
    address = local.prometheus_address
    port    = 9090
    fqdn    = local.prometheus_record ? "${local.prefix}-prometheus.${var.monitoring.dns_zone}" : null
  } : null
}

data "openstack_networking_router_v2" "intranet" {
  count     = module.planes.nat.intranet ? 1 : 0
  router_id = module.platform.networks[local.network].routers["intranet"].id
}
