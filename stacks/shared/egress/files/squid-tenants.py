#!/usr/bin/env python3
"""Renders the tenants of the shared egress from the instance metadata into /etc/squid/tenants.conf,
atomically and only when they changed, then reloads Squid. Any error leaves the file untouched.

Each tenant is a JSON object {"s": sources, "d": names}, cut into items "tenant-<name>-<n>" of at
most 255 characters (the limit of a metadata value); the item "tenants" counts the items, so that
an unreadable answer is never mistaken for "no tenant".
"""

import json
import os
import re
import subprocess
import sys
import tempfile
import urllib.request

URL = "http://169.254.169.254/openstack/latest/meta_data.json"
TARGET = "/etc/squid/tenants.conf"
ITEM = re.compile(r"^tenant-([a-z0-9][a-z0-9-]*)-(\d+)$")

try:
    with urllib.request.urlopen(URL, timeout=5) as r:
        meta = json.load(r).get("meta", {})
    expected = int(meta["tenants"])
    parts = {}
    for k, v in meta.items():
        m = ITEM.match(k)
        if m:
            parts.setdefault(m.group(1), {})[int(m.group(2))] = v
    if sum(len(p) for p in parts.values()) != expected:
        raise ValueError(f"{sum(len(p) for p in parts.values())} items for {expected} expected")
    tenants = {name: json.loads("".join(p[i] for i in sorted(p))) for name, p in parts.items()}
except Exception as e:
    print(f"metadata unreadable, tenants unchanged: {e}", file=sys.stderr)
    sys.exit(0)

lines = []
for name in sorted(tenants):
    t, key = tenants[name], name.replace("-", "_")
    lines += [f"acl src_{key} src {' '.join(t['s'])}", f"acl dst_{key} dstdomain {' '.join(t['d'])}",
              f"http_access allow src_{key} dst_{key}"]
content = "".join(line + "\n" for line in lines)
try:
    with open(TARGET) as f:
        if f.read() == content:
            sys.exit(0)
except FileNotFoundError:
    pass
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(TARGET), prefix=".tenants-")
with os.fdopen(fd, "w") as f:
    f.write(content)
os.chmod(tmp, 0o644)
os.replace(tmp, TARGET)
print(f"tenants updated: {', '.join(sorted(tenants)) or 'none'}")
# Squid not started yet (first boot): cloud-init starts it after this first rendering.
subprocess.run(["systemctl", "try-reload-or-restart", "squid"], check=False)
