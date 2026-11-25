output "bootstrap" {
  description = "Floating IP of the bootstrap instance on the administration network, or null once it is removed."
  value       = module.cluster.bootstrap
}

output "services" {
  description = "What the consumers reach, on the internal services plane: the internal ingress (HTTPS, names of cluster.domains) and the TCP echo, at a floating IP of the plane with NAT, at their address in the cluster network otherwise. The consumers admit nothing from the cluster for them."
  value = merge({
    ingress = "${module.cluster.entries.internal}:443"
    echo    = "${module.cluster.entries.echo}:7000"
  }, { for k, s in var.services : k => [for p in s.ports : "${module.cluster.entries[k]}:${p}"] })
}

output "domains" {
  description = "Names of the HTTP services and the address they resolve to; as records, in dns_records."
  value       = { for d in var.cluster.domains : d => module.cluster.entries.internal }
}

output "dns_records" {
  description = "The records of cluster.domains in internal_zone (ADR-0016, D2), keyed \"<name> <type>\", each { zone, name, type, ttl, records }: written in Designate with dns = \"designate\", to publish with your DNS provider otherwise (a for_each of its record resource). Empty without internal_zone."
  value = var.internal_zone == null ? {} : {
    for d in var.cluster.domains : "${d} A" => {
      zone    = var.internal_zone.name
      name    = trimsuffix(d, ".${trimsuffix(var.internal_zone.name, ".")}")
      type    = "A"
      ttl     = var.internal_zone.ttl
      records = [module.cluster.entries.internal]
    }
  }
}

output "sources" {
  description = "Addresses the cluster connects from on each plane it joins, for the admission rules of what it calls (allowed_sources)."
  value       = module.cluster.sources
}

output "manifests" {
  description = "Rendered Cluster API manifests, as written on the bootstrap instance. Sensitive with certificates (the DNS provider's key)."
  sensitive   = true
  value       = module.cluster.manifests
}

output "scripts" {
  description = "Rendered scripts: create-cluster.sh and delete-cluster.sh, written on the bootstrap instance at its creation; update-cluster.sh, run from the administration sources after each apply (scripts/cluster-files.sh writes them in a directory)."
  sensitive   = true
  value       = module.cluster.scripts
}
