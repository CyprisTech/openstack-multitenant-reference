# Traefik configuration, rendered here and written by cloud-init (ADR-0001, D8).

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
      file = { filename = "/etc/traefik/dynamic.yml" }
    }
    metrics = {
      prometheus = { entryPoint = "metrics", addRoutersLabels = true, addServicesLabels = true }
    }
    ping      = { entryPoint = "metrics" }
    api       = { dashboard = false }
    log       = { level = "INFO" }
    accessLog = {}
  })

  route_keys = { for domain in keys(var.routes) : domain => replace(domain, ".", "-") }

  tcp_config = {
    serversTransports = {
      proxy-v2 = { proxyProtocol = { version = 2 } }
    }
    middlewares = {
      for domain, r in var.routes : "${local.route_keys[domain]}-limit" => {
        inFlightConn = { amount = r.max_connections }
      }
    }
    routers = {
      for domain, r in var.routes : local.route_keys[domain] => {
        entryPoints = ["websecure"]
        rule        = "HostSNI(`${domain}`)"
        service     = local.route_keys[domain]
        middlewares = ["${local.route_keys[domain]}-limit"]
        tls         = { passthrough = true }
      }
    }
    services = {
      for domain, r in var.routes : local.route_keys[domain] => {
        loadBalancer = merge(
          { servers = [for b in r.backends : { address = b }] },
          r.proxy_protocol ? { serversTransport = "proxy-v2" } : {}
        )
      }
    }
  }

  # With no route, Traefik only redirects port 80 and refuses TLS connections.
  traefik_dynamic = length(var.routes) == 0 ? "{}\n" : yamlencode({ tcp = local.tcp_config })

  traefik_unit = <<-EOT
    [Unit]
    Description=Traefik (public entry point)
    Wants=network-online.target
    After=network-online.target

    [Service]
    ExecStartPre=-/usr/bin/podman rm --force traefik
    ExecStart=/usr/bin/podman run --rm --name traefik --network host \
      --volume /etc/traefik:/etc/traefik:ro \
      ${var.traefik_image} --configFile=/etc/traefik/traefik.yml
    ExecStop=/usr/bin/podman stop --time 10 traefik
    Restart=always
    RestartSec=5

    [Install]
    WantedBy=multi-user.target
  EOT
}
