output "backends" {
  description = "Published backends (\"address:443\" on svc_public), to use as routes of the entry point."
  value       = [for name in local.instances : "${module.web.instances[name].ports["main"].floating_ip}:443"]
}

output "routes" {
  description = "Routes for the entry point (stack 20, variable routes)."
  value = {
    for d in var.domains : d => {
      backends = [for name in local.instances : "${module.web.instances[name].ports["main"].floating_ip}:443"]
    }
  }
}

output "edge_sources" {
  description = "Addresses of the entry point admitted on port 443."
  value       = local.edge_sources
}

output "instances" {
  description = "Web instances and their private addresses."
  value       = { for name in local.instances : name => module.web.instances[name].ports["main"].ip }
}
