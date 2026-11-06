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
