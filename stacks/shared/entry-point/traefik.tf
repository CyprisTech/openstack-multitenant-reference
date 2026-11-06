# Traefik configuration: the static part written by cloud-init (ADR-0001, D8), the routes
# delivered through the instance metadata (ADR-0006, D3).

locals {
  traefik_static = yamlencode({
    entryPoints = {
      web = {
        address       = ":80"
        proxyProtocol = { trustedIPs = [var.edge_cidr] }
        http = {
          redirections = { entryPoint = { to = "websecure", scheme = "https", permanent = true } }
        }
      }
      websecure = {
        address       = ":443"
        proxyProtocol = { trustedIPs = [var.edge_cidr] }
      }
      metrics = {
        address = ":8082"
      }
    }
    providers = {
      file = { directory = "/etc/traefik/dynamic", watch = true }
    }
    metrics = {
      prometheus = { entryPoint = "metrics", addRoutersLabels = true, addServicesLabels = true }
    }
    ping      = { entryPoint = "metrics" }
    api       = { dashboard = false }
    log       = { level = "INFO" }
    accessLog = {}
  })

  # Routes (ADR-0006, D3): one metadata item per domain on every Traefik instance, updated in
  # place. The instance renders them into Traefik's dynamic configuration (traefik-routes, below);
  # the item "routes" carries their number, so that an unreadable answer is never mistaken for
  # "no route".
  route_metadata = merge(
    { routes = tostring(length(var.domains)) },
    {
      for domain, r in var.domains : "route-${domain}" => jsonencode({
        b = r.backends
        p = r.proxy_protocol
        m = r.max_connections
      })
    },
  )

  # Renders the routes of the metadata service into /etc/traefik/dynamic/routes.yml (JSON is
  # YAML), atomically, and only when they changed. Any error leaves the current file untouched.
  traefik_routes = file("${path.module}/files/traefik-routes.py")

  traefik_routes_units = {
    for unit in ["service", "timer"] :
    "/etc/systemd/system/traefik-routes.${unit}" => file("${path.module}/files/traefik-routes.${unit}")
  }

  traefik_unit = templatefile("${path.module}/files/traefik.service.tftpl", { image = var.traefik_image })
}
