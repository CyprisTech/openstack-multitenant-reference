#!/usr/bin/env python3
"""Executable reachability matrix (ADR-0001, D6).

Reads the outputs of the deployed stacks, runs TCP probes from inside the tenants (through
their bastions) and from the machine running the test, and compares every result with the
matrix of docs/architecture.md. Exits with status 1 if any row differs.

    tests/reachability/check.py --stacks stacks --collector tests/integration/collector \
        --user debug --key ~/.ssh/id_ed25519 [--tool tofu]

Requirements: the stacks 20-public-edge, 30-tenants/web and 30-tenants/isolated applied with
bastions, the test collector applied, and the public domains routed by the entry point.
Probes only open TCP connections; nothing is changed.
"""

import argparse
import json
import os
import shlex
import subprocess
import sys


def outputs(tool, directory):
    out = subprocess.run([tool, "output", "-json"], cwd=directory, check=True, capture_output=True, text=True).stdout
    return {k: v["value"] for k, v in json.loads(out).items()}


class Prober:
    def __init__(self, user, key):
        self.base = [
            "ssh", "-i", os.path.expanduser(key), "-o", "BatchMode=yes", "-o", "LogLevel=ERROR",
            "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null", "-o", "ConnectTimeout=10",
        ]
        self.user = user

    def remote(self, jump, host, target, port):
        """TCP probe run on `host` (reached through the bastion `jump`, or directly if host is None)."""
        probe = f"timeout 5 bash -c '</dev/tcp/{target}/{port}' 2>/dev/null && echo open || echo closed"
        cmd = list(self.base)
        if host is None:
            cmd += [f"{self.user}@{jump}", probe]
        else:
            proxy = " ".join(shlex.quote(a) for a in self.base + ["-W", "%h:%p", f"{self.user}@{jump}"])
            cmd += ["-o", f"ProxyCommand={proxy}", f"{self.user}@{host}", probe]
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
        if r.returncode != 0 or r.stdout.strip() not in ("open", "closed"):
            return "error: " + (r.stderr.strip().splitlines() or ["ssh failed"])[-1]
        return r.stdout.strip()

    @staticmethod
    def local(target, port):
        import socket
        try:
            with socket.create_connection((target, port), timeout=5):
                return "open"
        except OSError:
            return "closed"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--stacks", default="stacks")
    ap.add_argument("--collector", default="tests/integration/collector")
    ap.add_argument("--user", default="debug")
    ap.add_argument("--key", required=True)
    ap.add_argument("--tool", default="tofu")
    args = ap.parse_args()

    edge = outputs(args.tool, os.path.join(args.stacks, "20-public-edge"))
    web = outputs(args.tool, os.path.join(args.stacks, "30-tenants", "web"))
    iso = outputs(args.tool, os.path.join(args.stacks, "30-tenants", "isolated"))
    col = outputs(args.tool, args.collector)
    p = Prober(args.user, args.key)

    edge_vm = sorted(edge["instances"].items())[0]
    web_vm = sorted(web["instances"].items())[0]
    iso_vm = sorted(iso["instances"].items())[0]
    public_ip = edge["load_balancer"]["floating_ip"]
    web_published = [b.split(":")[0] for b in web["backends"]]
    mon = {**edge["monitoring_targets"], **web["monitoring_targets"], **iso["monitoring_targets"]}

    rows = []  # (from, to, port, expected, probe)
    rows.append(("test runner", "entry point (public IP)", 443, "open", lambda: p.local(public_ip, 443)))
    rows.append(("test runner", "entry point (public IP)", 80, "open", lambda: p.local(public_ip, 80)))
    for ip in web_published:
        rows.append(("test runner", f"web, published address {ip}", 443, "closed", lambda ip=ip: p.local(ip, 443)))
    for ip in web_published:
        rows.append((f"edge {edge_vm[0]}", f"web, published address {ip}", 443, "open",
                     lambda ip=ip: p.remote(edge["bastion"], edge_vm[1], ip, 443)))
    for name, t in sorted(mon.items()):
        ports = [9100] + ([8082] if name in edge["monitoring_targets"] else [])
        for port in ports:
            rows.append(("collector", f"{name} (monitoring {t['address']})", port, "open",
                         lambda a=t["address"], port=port: p.remote(col["address"], None, a, port)))
    for name, t in sorted({**web["monitoring_targets"], **iso["monitoring_targets"]}.items()):
        rows.append((f"edge {edge_vm[0]}", f"{name} (monitoring {t['address']})", 9100, "closed",
                     lambda a=t["address"]: p.remote(edge["bastion"], edge_vm[1], a, 9100)))
    for name, t in sorted({**edge["monitoring_targets"], **iso["monitoring_targets"]}.items()):
        rows.append((f"web {web_vm[0]}", f"{name} (monitoring {t['address']})", 9100, "closed",
                     lambda a=t["address"]: p.remote(web["bastion"], web_vm[1], a, 9100)))
    rows.append((f"web {web_vm[0]}", f"edge {edge_vm[0]} (private {edge_vm[1]})", 443, "closed",
                 lambda: p.remote(web["bastion"], web_vm[1], edge_vm[1], 443)))
    for ip in web_published:
        rows.append((f"isolated {iso_vm[0]}", f"web, published address {ip}", 443, "closed",
                     lambda ip=ip: p.remote(iso["bastion"], iso_vm[1], ip, 443)))
    for name, t in sorted({**edge["monitoring_targets"], **web["monitoring_targets"]}.items()):
        rows.append((f"isolated {iso_vm[0]}", f"{name} (monitoring {t['address']})", 9100, "closed",
                     lambda a=t["address"]: p.remote(iso["bastion"], iso_vm[1], a, 9100)))
    rows.append((f"isolated {iso_vm[0]}", "Internet (1.1.1.1)", 443, "closed",
                 lambda: p.remote(iso["bastion"], iso_vm[1], "1.1.1.1", 443)))

    failures = 0
    print(f"{'from':<22} {'to':<52} {'port':>5}  {'expected':<8} {'actual':<8}")
    for src, dst, port, expected, probe in rows:
        actual = probe()
        ok = actual == expected
        failures += 0 if ok else 1
        print(f"{src:<22} {dst:<52} {port:>5}  {expected:<8} {actual:<8} {'✅' if ok else '❌'}")
    print(f"\n{len(rows) - failures}/{len(rows)} rows as expected")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
