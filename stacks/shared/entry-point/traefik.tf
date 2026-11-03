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
  traefik_routes = <<-EOT
    #!/usr/bin/env python3
    import json, os, sys, tempfile, urllib.request

    URL = "http://169.254.169.254/openstack/latest/meta_data.json"
    TARGET = "/etc/traefik/dynamic/routes.yml"

    try:
        with urllib.request.urlopen(URL, timeout=5) as r:
            meta = json.load(r).get("meta", {})
        expected = int(meta["routes"])
        routes = {k[len("route-"):]: json.loads(v) for k, v in meta.items() if k.startswith("route-")}
    except Exception as e:
        print(f"metadata unreadable, routes unchanged: {e}", file=sys.stderr)
        sys.exit(0)
    if len(routes) != expected:
        print(f"{len(routes)} routes for {expected} expected, routes unchanged", file=sys.stderr)
        sys.exit(0)

    def key(domain):
        return domain.replace(".", "-")

    tcp = {
        "serversTransports": {"proxy-v2": {"proxyProtocol": {"version": 2}}},
        "middlewares": {f"{key(d)}-limit": {"inFlightConn": {"amount": r["m"]}} for d, r in routes.items()},
        "routers": {
            key(d): {
                "entryPoints": ["websecure"],
                "rule": f"HostSNI(`{d}`)",
                "service": key(d),
                "middlewares": [f"{key(d)}-limit"],
                "tls": {"passthrough": True},
            }
            for d in routes
        },
        "services": {
            key(d): {
                "loadBalancer": dict(
                    {"servers": [{"address": b} for b in r["b"]]},
                    **({"serversTransport": "proxy-v2"} if r["p"] else {}),
                )
            }
            for d, r in routes.items()
        },
    }
    # With no route, Traefik only redirects port 80 and refuses TLS connections.
    content = json.dumps({"tcp": tcp} if routes else {}, indent=2, sort_keys=True) + "\n"
    try:
        with open(TARGET) as f:
            if f.read() == content:
                sys.exit(0)
    except FileNotFoundError:
        pass
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(TARGET), prefix=".routes-")
    with os.fdopen(fd, "w") as f:
        f.write(content)
    os.chmod(tmp, 0o644)
    os.replace(tmp, TARGET)
    print(f"routes updated: {', '.join(sorted(routes)) or 'none'}")
  EOT

  traefik_routes_units = {
    "/etc/systemd/system/traefik-routes.service" = <<-EOT
      [Unit]
      Description=Render the Traefik routes from the instance metadata

      [Service]
      Type=oneshot
      ExecStart=/usr/local/sbin/traefik-routes
    EOT
    "/etc/systemd/system/traefik-routes.timer"   = <<-EOT
      [Unit]
      Description=Render the Traefik routes from the instance metadata, every 10 seconds

      [Timer]
      OnBootSec=5
      OnUnitActiveSec=10
      AccuracySec=1

      [Install]
      WantedBy=timers.target
    EOT
  }

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
