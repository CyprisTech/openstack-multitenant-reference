#!/usr/bin/env python3
"""Isolation test: every flow of docs/reference/isolation-matrix.md, checked on a deployment.

Reads the outputs of the deployed stacks, runs TCP probes from inside the tenants and the
receiver (through their bastions) and from the machine running the test, asks the receiver
which tenants pushed metrics, and compares every result with the expected one. Exits with
status 1 if any row differs.

The same rows hold whatever the planes (ADR-0004): the addresses come from the stacks'
outputs. Each stack may live in its own project; the test only reads their outputs.

    tests/isolation/check.py --stacks stacks --receiver tests/fixtures/receiver \
        --user ops --key ~/.ssh/id_ed25519 [--tool tofu] \
        [--web web.json] [--private private.json] \
        [--published-kubeconfig published.kubeconfig --internal-service tests/fixtures/internal-service] \
        [--acme tests/fixtures/acme] [--shared-kubeconfig shared.kubeconfig]

Requirements: the stacks shared/entry-point, the web tenant (tenants/vm) and the private tenant
(tenants/vm with exposure = "none" and egress = "none", ADR-0016 D1) applied with bastions and
pushing to the test receiver, and the receiver applied. A tenant is read from its stack's
directory, or from a file of its outputs (tofu output -json > web.json) when several tenants share
the directory, each with its own state: --web, --private and --egress-tenant. With
--published-kubeconfig, the rows of the published cluster are added: probes from the cluster run
in a short-lived pod, and the internal demonstration service must be applied. Probes only open
TCP connections and read the receiver; the only object created is the probe pod, deleted after
use.

With --shared-kubeconfig, the rows of the shared cluster (a Kubernetes cluster for shared
services) are added (stacks/shared/kubernetes, its demonstration services applied): the web
tenant, its consumer, reaches the internal ingress and the TCP echo; the other tenants do not; a
pod of the cluster reaches no tenant and, from another namespace, no backend of a service.

With --acme, the rows of the certificates are added (ADR-0008): each published domain, reached
through the entry point, presents a certificate for its name issued by the test authority, and
a tenant's TSIG key can change its own _acme-challenge records only (nsupdate on the web
instance; the record it adds is deleted at once).

With --zone, the rows of name resolution are added (ADR-0016, D3): every instance resolves a
public name (--public-name) through the resolvers of its subnet, and the tenants also resolve the
zone of the landing zone, whose names they use (the entry point and the receiver reach the
tenants by address);
with --resolver (tests/fixtures/resolver), the private tenant uses that resolver, behind the
internal services plane.

With --egress (stacks/shared/egress) and --egress-tenant (a vm tenant with egress = "shared"),
the rows of the shared egress are added (ADR-0016, D1): through the proxy,
that tenant reaches a declared name (--egress-allowed) and not another (--egress-refused); it has
no direct way to the Internet; the web and private tenants, not declared, do not reach the proxy.
"""

import argparse
import json
import os
import shlex
import socket
import ssl
import subprocess
import sys


def outputs(tool, source):
    """The outputs of a stack: read in its directory, or from a file of tofu output -json (a tenant
    of a directory shared by several tenants, each with its own state)."""
    if os.path.isfile(source):
        with open(source) as f:
            return {k: v["value"] for k, v in json.load(f).items()}
    out = subprocess.run([tool, "output", "-json"], cwd=source, check=True, capture_output=True, text=True).stdout
    return {k: v["value"] for k, v in json.loads(out).items()}


class Prober:
    def __init__(self, user, key):
        self.base = [
            "ssh", "-i", os.path.expanduser(key), "-o", "BatchMode=yes", "-o", "LogLevel=ERROR",
            "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null", "-o", "ConnectTimeout=10",
        ]
        self.user = user

    def pod(self, kubectl, target, port):
        """TCP probe run from a pod of the cluster."""
        r = subprocess.run(kubectl + ["-n", "default", "exec", "isolation-probe", "--", "sh", "-c",
                                      f"nc -z -w 5 {target} {port} && echo open || echo closed"],
                           capture_output=True, text=True, timeout=60)
        out = r.stdout.strip().splitlines()
        return out[-1] if out and out[-1] in ("open", "closed") else "error: " + (r.stderr.strip() or "kubectl failed")

    def pod_ipv6(self, kubectl):
        """Global IPv6 addresses and IPv6 default route of the probe pod: none, or what is found."""
        r = subprocess.run(kubectl + ["-n", "default", "exec", "isolation-probe", "--", "sh", "-c",
                                      "ip -6 -o addr show scope global; ip -6 route show default; echo done"],
                           capture_output=True, text=True, timeout=60)
        out = r.stdout.strip().splitlines()
        if not out or out[-1] != "done":
            return "error: " + (r.stderr.strip() or "kubectl failed")[:60]
        return "none" if len(out) == 1 else "present: " + out[0][:60]

    def remote(self, jump, host, target, port):
        """TCP probe run on `host` (reached through the bastion `jump`, or directly if host is None)."""
        probe = f"timeout 5 bash -c '</dev/tcp/{target}/{port}' 2>/dev/null && echo open || echo closed"
        out = self.run(jump, host, probe)
        return out if out in ("open", "closed") or out.startswith("error") else "error: " + out

    def run(self, jump, host, command):
        """Runs `command` on `host` through the bastion `jump`; returns its output, or an error."""
        cmd = list(self.base)
        if host is None:
            cmd += [f"{self.user}@{jump}", command]
        else:
            proxy = " ".join(shlex.quote(a) for a in self.base + ["-W", "%h:%p", f"{self.user}@{jump}"])
            cmd += ["-o", f"ProxyCommand={proxy}", f"{self.user}@{host}", command]
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
        if r.returncode != 0:
            return "error: " + (r.stderr.strip().splitlines() or ["ssh failed"])[-1]
        return r.stdout.strip()

    @staticmethod
    def local(target, port):
        try:
            with socket.create_connection((target, port), timeout=5):
                return "open"
        except OSError:
            return "closed"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--stacks", default="stacks")
    ap.add_argument("--receiver", default="tests/fixtures/receiver")
    ap.add_argument("--web", help="the web tenant: its directory or a file of its outputs (default: <stacks>/tenants/vm)")
    ap.add_argument("--private", help="the private tenant: its directory or a file of its outputs (required)")
    ap.add_argument("--user", default="ops")
    ap.add_argument("--published-kubeconfig")
    ap.add_argument("--kubectl", default="kubectl")
    ap.add_argument("--internal-service", default="tests/fixtures/internal-service")
    ap.add_argument("--key", required=True)
    ap.add_argument("--tool", default="tofu")
    ap.add_argument("--acme", help="directory of the test ACME authority (tests/fixtures/acme)")
    ap.add_argument("--shared-kubeconfig", help="kubeconfig of the shared cluster (stacks/shared/kubernetes)")
    ap.add_argument("--zone", help="zone of the landing zone, which every instance must resolve")
    ap.add_argument("--public-name", default="openstack.org", help="a public name every instance must resolve")
    ap.add_argument("--resolver", help="directory of the test resolver (tests/fixtures/resolver), used by the private tenant")
    ap.add_argument("--egress", help="directory of the shared egress (stacks/shared/egress)")
    ap.add_argument("--egress-tenant", help="the tenant with egress = shared: its directory or a file of its outputs")
    ap.add_argument("--egress-allowed", default="http://archive.ubuntu.com/ubuntu/", help="URL of a declared name")
    ap.add_argument("--egress-refused", default="https://openstack.org/", help="a URL of a name not declared")
    args = ap.parse_args()

    edge = outputs(args.tool, os.path.join(args.stacks, "shared", "entry-point"))
    if not args.private:
        ap.error("--private is required: the private tenant's directory or a file of its outputs")
    web = outputs(args.tool, args.web or os.path.join(args.stacks, "tenants", "vm"))
    prv = outputs(args.tool, args.private)
    rcv = outputs(args.tool, args.receiver)
    p = Prober(args.user, args.key)

    edge_vm = sorted(edge["instances"].items())[0]
    web_vm = sorted(web["instances"].items())[0]
    prv_vm = sorted(prv["instances"].items())[0]
    public_ip = edge["load_balancer"]["floating_ip"]
    service = web["service_address"].split(":")[0]
    receiver = rcv["receiver_url"].split("//")[1].split(":")[0]

    def from_edge(target, port):
        return lambda: p.remote(edge["bastion"], edge_vm[1], target, port)

    def from_web(target, port):
        return lambda: p.remote(web["bastion"], web_vm[1], target, port)

    def from_private(target, port):
        return lambda: p.remote(prv["bastion"], prv_vm[1], target, port)

    def from_receiver(target, port):
        return lambda: p.remote(rcv["bastion"], rcv["address"], target, port)

    def pushed(tenant):
        """Whether the receiver holds recent series pushed by the tenant (instant query: the last
        5 minutes)."""
        query = f"count({{tenant=\"{tenant}\"}})"
        out = p.run(rcv["bastion"], rcv["address"],
                    f"curl -sfG --data-urlencode {shlex.quote('query=' + query)} http://localhost:9090/api/v1/query")
        try:
            return "yes" if json.loads(out)["data"]["result"] else "no"
        except (ValueError, KeyError):
            return "error: " + out[:60]

    probe_pods = []

    def start_probe(kubeconfig):
        """Starts the probe pod in the default namespace of a cluster; returns its kubectl."""
        kubectl = [args.kubectl, "--kubeconfig", kubeconfig, "--request-timeout=30s"]
        # A probe pod left by an interrupted run would block the new one.
        for a in (["-n", "default", "delete", "pod", "isolation-probe", "--ignore-not-found", "--wait=true"],
                  ["run", "isolation-probe", "-n", "default", "--image=docker.io/library/busybox:1.37",
                   "--restart=Never", "--command", "--", "sleep", "600"],
                  ["wait", "-n", "default", "--for=condition=Ready", "pod/isolation-probe", "--timeout=120s"]):
            subprocess.run(kubectl + a, check=True, capture_output=True, text=True)
        probe_pods.append(kubectl)
        return kubectl

    def kget(kubectl, *a):
        return subprocess.run(kubectl + list(a), check=True, capture_output=True, text=True).stdout.strip()

    rows = []  # (from, to, port, expected, probe)
    tenants = ((f"edge {edge_vm[0]}", from_edge), (f"web {web_vm[0]}", from_web), (f"private {prv_vm[0]}", from_private))
    # Publication (ADR-0006): the entry point reaches the tenant's service address, and only it.
    rows.append(("test runner", "entry point (public IP)", 443, "open", lambda: p.local(public_ip, 443)))
    rows.append(("test runner", "entry point (public IP)", 80, "open", lambda: p.local(public_ip, 80)))
    rows.append(("test runner", f"web service address {service}", 443, "closed", lambda: p.local(service, 443)))
    rows.append((f"edge {edge_vm[0]}", f"web service address {service}", 443, "open", from_edge(service, 443)))
    rows.append((f"edge {edge_vm[0]}", f"web {web_vm[0]} (private {web_vm[1]})", 443, "closed", from_edge(web_vm[1], 443)))
    rows.append((f"private {prv_vm[0]}", f"web service address {service}", 443, "closed", from_private(service, 443)))
    rows.append((f"web {web_vm[0]}", f"edge {edge_vm[0]} (private {edge_vm[1]})", 443, "closed", from_web(edge_vm[1], 443)))
    # Monitoring (ADR-0007): every tenant pushes to the receiver; nothing reaches a tenant's metrics.
    for name, probe in tenants:
        rows.append((name, f"receiver {receiver}", 9090, "open", probe(receiver, 9090)))
    for name, ip in ((edge_vm[0], edge_vm[1]), (web_vm[0], web_vm[1]), (prv_vm[0], prv_vm[1])):
        rows.append(("receiver", f"{name} metrics (private {ip})", 9100, "closed", from_receiver(ip, 9100)))
    # Lateral movement (docs/concepts/architecture.md): a tenant or the entry point reaches the receiver on its port only,
    # and the receiver reaches neither a tenant's service address nor the entry point.
    for name, probe in tenants:
        rows.append((name, f"receiver {receiver} (SSH)", 22, "closed", probe(receiver, 22)))
    rows.append(("receiver", f"web service address {service}", 443, "closed", from_receiver(service, 443)))
    rows.append(("receiver", f"edge {edge_vm[0]} (private {edge_vm[1]})", 443, "closed", from_receiver(edge_vm[1], 443)))
    for tenant in ("edge", "web", "private"):
        rows.append(("receiver", f"series pushed by {tenant}", "-", "yes", lambda t=tenant: pushed(t)))
    # Tenant to tenant, at the private addresses, and the private tenant's way out (no egress).
    rows.append((f"web {web_vm[0]}", f"private {prv_vm[0]} (private {prv_vm[1]})", 22, "closed", from_web(prv_vm[1], 22)))
    rows.append((f"private {prv_vm[0]}", f"web {web_vm[0]} (private {web_vm[1]})", 443, "closed", from_private(web_vm[1], 443)))
    rows.append((f"private {prv_vm[0]}", "Internet (1.1.1.1)", 443, "closed", from_private("1.1.1.1", 443)))
    # IPv6 (ADR-0015, D2): no global IPv6 address and no IPv6 default route on any instance, so
    # that no IPv6 path exists next to the IPv4 rules. A cloud that adds IPv6 by itself shows here.
    def ipv6(jump, host):
        out = p.run(jump, host, "ip -6 -o addr show scope global; ip -6 route show default")
        if out.startswith("error"):
            return out
        return "none" if not out else "present: " + out.splitlines()[0][:60]

    for name, jump, host in ((f"edge {edge_vm[0]}", edge["bastion"], edge_vm[1]), (f"web {web_vm[0]}", web["bastion"], web_vm[1]),
                             (f"private {prv_vm[0]}", prv["bastion"], prv_vm[1]), ("receiver", rcv["bastion"], rcv["address"])):
        rows.append((name, "routed IPv6 (global address, default route)", "-", "none", lambda j=jump, h=host: ipv6(j, h)))

    # Name resolution (ADR-0016, D3): the resolvers of each subnet answer the zone of the landing
    # zone and public names; the private tenant, without egress, through the resolver behind the
    # internal services plane.
    def resolves(jump, host, name, rtype="A"):
        out = p.run(jump, host, f"resolvectl query --legend=no -t {rtype} {shlex.quote(name)} 2>&1 | head -1")
        if out.startswith("error"):
            return out
        return "yes" if out and "resolve call failed" not in out and "not found" not in out.lower() else "no: " + out[:50]

    def resolvers(jump, host):
        return p.run(jump, host, "resolvectl dns 2>/dev/null | awk -F': ' 'NF>1 {print $2}' | tr '\\n' ' '").strip()

    if args.zone:
        instances = ((f"edge {edge_vm[0]}", edge["bastion"], edge_vm[1]), (f"web {web_vm[0]}", web["bastion"], web_vm[1]),
                     (f"private {prv_vm[0]}", prv["bastion"], prv_vm[1]), ("receiver", rcv["bastion"], rcv["address"]))
        for name, jump, host in instances:
            if name.startswith(("web", "private")):
                rows.append((name, f"resolves the zone {args.zone} (SOA)", 53, "yes",
                             lambda j=jump, h=host: resolves(j, h, args.zone, "SOA")))
            rows.append((name, f"resolves {args.public_name}", 53, "yes",
                         lambda j=jump, h=host: resolves(j, h, args.public_name)))
    if args.resolver:
        resolver = outputs(args.tool, args.resolver)["resolver"]

        def uses_resolver():
            out = resolvers(prv["bastion"], prv_vm[1])
            return "yes" if resolver in out.split() else "no: " + (out or "none")[:50]

        rows.append((f"private {prv_vm[0]}", f"resolver in use {resolver}", "-", "yes", uses_resolver))

    if args.egress:
        proxy = outputs(args.tool, args.egress)["proxy"]
        proxy_host, proxy_port = proxy.split("//")[1].rsplit(":", 1)
        if not args.egress_tenant:
            ap.error("--egress needs --egress-tenant: the tenant's directory or a file of its outputs")
        egt = outputs(args.tool, args.egress_tenant)
        eg_vm = sorted(egt["instances"].items())[0]

        def through_proxy(url):
            """HTTP status of a request through the proxy, from the tenant with the shared egress:
            open when the name is declared, refused (403 from the proxy) otherwise."""
            # A refused HTTPS name fails the CONNECT (curl exits 56, http_connect 403); a refused HTTP
            # name answers 403. Both are read from the codes, whatever curl's exit status.
            out = p.run(egt["bastion"], eg_vm[1],
                        f"curl -s -o /dev/null -w '%{{http_code}} %{{http_connect}}' --max-time 15 "
                        f"-x {shlex.quote(proxy)} {shlex.quote(url)}; true")
            if out.startswith("error"):
                return out
            codes = out.split()
            if codes and codes[0][:1] in "23":
                return "open"
            return "refused" if "403" in codes else f"error: {out.strip()}"

        rows.append((f"egress {eg_vm[0]}", f"{args.egress_allowed} through the proxy", proxy_port, "open",
                     lambda: through_proxy(args.egress_allowed)))
        rows.append((f"egress {eg_vm[0]}", f"{args.egress_refused} through the proxy", proxy_port, "refused",
                     lambda: through_proxy(args.egress_refused)))
        rows.append((f"egress {eg_vm[0]}", "Internet (1.1.1.1), directly", 443, "closed",
                     lambda: p.remote(egt["bastion"], eg_vm[1], "1.1.1.1", 443)))
        rows.append((f"web {web_vm[0]}", f"shared egress {proxy_host} (not declared)", proxy_port, "closed",
                     from_web(proxy_host, int(proxy_port))))
        rows.append((f"private {prv_vm[0]}", f"shared egress {proxy_host} (not declared)", proxy_port, "closed",
                     from_private(proxy_host, int(proxy_port))))
        rows.append((f"egress {eg_vm[0]}", "routed IPv6 (global address, default route)", "-", "none",
                     lambda: ipv6(egt["bastion"], eg_vm[1])))

    probe_pod = None
    if args.published_kubeconfig:
        kubectl = [args.kubectl, "--kubeconfig", args.published_kubeconfig, "--request-timeout=30s"]

        # The ingress address created by the stack, and the one the Service carries: the cloud
        # controller manager silently allocates another address when the requested one is
        # unavailable.
        plat = outputs(args.tool, os.path.join(args.stacks, "tenants", "kubernetes"))
        ingress = next(iter(plat["published_domains"].values()))["backends"][0].split(":")[0]
        svc_ingress = kget(kubectl, "get", "svc", "-A", "-l", "app.kubernetes.io/name=traefik", "-o",
                           "jsonpath={.items[0].status.loadBalancer.ingress[0].ip}")
        server = kget(kubectl, "config", "view", "--minify", "-o", "jsonpath={.clusters[0].cluster.server}")
        api = server.split("//")[1].split(":")[0]
        internal = outputs(args.tool, args.internal_service)["address"]
        probe_pod = start_probe(args.published_kubeconfig)

        rows.append(("published Service", "ingress on the stack address", "-", "yes",
                     lambda: "yes" if svc_ingress == ingress else f"no: {svc_ingress}"))
        rows.append((f"edge {edge_vm[0]}", f"published ingress {ingress}", 443, "open", from_edge(ingress, 443)))
        rows.append(("test runner", f"published ingress {ingress}", 443, "closed", lambda: p.local(ingress, 443)))
        rows.append((f"web {web_vm[0]}", f"published ingress {ingress}", 443, "closed", from_web(ingress, 443)))
        rows.append((f"private {prv_vm[0]}", f"published ingress {ingress}", 443, "closed", from_private(ingress, 443)))
        rows.append(("published pod", f"receiver {receiver}", 9090, "open", lambda: p.pod(probe_pod, receiver, 9090)))
        rows.append(("receiver", "series pushed by published", "-", "yes", lambda: pushed("published")))
        rows.append(("test runner (administrator)", f"published Kubernetes API {api}", 6443, "open", lambda: p.local(api, 6443)))
        for tenant, out in (("edge", edge), ("web", web), ("private", prv)):
            rows.append(("published pod", f"{tenant} bastion {out['bastion']} (SSH)", 22, "closed",
                         lambda b=out["bastion"]: p.pod(probe_pod, b, 22)))
        rows.append(("published pod", f"internal service {internal}", 8080, "open", lambda: p.pod(probe_pod, internal, 8080)))
        rows.append((f"web {web_vm[0]}", f"internal service {internal}", 8080, "closed", from_web(internal, 8080)))
        rows.append((f"private {prv_vm[0]}", f"internal service {internal}", 8080, "closed", from_private(internal, 8080)))
        rows.append((f"edge {edge_vm[0]}", f"internal service {internal}", 8080, "closed", from_edge(internal, 8080)))
        rows.append(("receiver", f"internal service {internal}", 8080, "closed", from_receiver(internal, 8080)))
        rows.append(("receiver", f"published ingress {ingress}", 443, "closed", from_receiver(ingress, 443)))
        rows.append(("published pod", "routed IPv6 (global address, default route)", "-", "none", lambda: p.pod_ipv6(probe_pod)))

    if args.shared_kubeconfig:
        # The shared cluster (spec: a Kubernetes cluster for shared services): the web
        # tenant is its consumer; the others are not.
        shared = outputs(args.tool, os.path.join(args.stacks, "shared", "kubernetes"))
        sk = start_probe(args.shared_kubeconfig)
        s_ingress = shared["services"]["ingress"].split(":")[0]
        s_echo = shared["services"]["echo"].split(":")[0]
        svc_internal = kget(sk, "-n", "traefik-internal", "get", "svc", "-l", "app.kubernetes.io/name=traefik", "-o",
                            "jsonpath={.items[0].status.loadBalancer.ingress[0].ip}")
        whoami_pod = kget(sk, "-n", "whoami", "get", "pod", "-l", "app=whoami", "-o", "jsonpath={.items[0].status.podIP}")
        echo_pod = kget(sk, "-n", "echo", "get", "pod", "-l", "app=echo", "-o", "jsonpath={.items[0].status.podIP}")
        rows.append(("shared Service", "internal ingress on the stack address", "-", "yes",
                     lambda: "yes" if svc_internal == s_ingress else f"no: {svc_internal}"))
        rows.append((f"web {web_vm[0]}", f"shared internal ingress {s_ingress}", 443, "open", from_web(s_ingress, 443)))
        rows.append((f"web {web_vm[0]}", f"shared TCP echo {s_echo}", 7000, "open", from_web(s_echo, 7000)))
        rows.append((f"private {prv_vm[0]}", f"shared internal ingress {s_ingress}", 443, "closed", from_private(s_ingress, 443)))
        rows.append((f"edge {edge_vm[0]}", f"shared internal ingress {s_ingress}", 443, "closed", from_edge(s_ingress, 443)))
        rows.append(("receiver", f"shared TCP echo {s_echo}", 7000, "closed", from_receiver(s_echo, 7000)))
        rows.append(("test runner", f"shared internal ingress {s_ingress}", 443, "closed", lambda: p.local(s_ingress, 443)))
        if probe_pod:
            rows.append(("published pod", f"shared internal ingress {s_ingress}", 443, "closed",
                         lambda: p.pod(probe_pod, s_ingress, 443)))
        rows.append(("shared pod", f"web {web_vm[0]} (private {web_vm[1]})", 443, "closed", lambda: p.pod(sk, web_vm[1], 443)))
        rows.append(("shared pod", f"web service address {service}", 443, "closed", lambda: p.pod(sk, service, 443)))
        for tenant, out in (("edge", edge), ("web", web), ("private", prv)):
            rows.append(("shared pod", f"{tenant} bastion {out['bastion']} (SSH)", 22, "closed",
                         lambda b=out["bastion"]: p.pod(sk, b, 22)))
        # Positive control: the shared cluster pushes to the receiver, so the probe pod reaches it.
        rows.append(("shared pod", f"receiver {receiver}", 9090, "open", lambda: p.pod(sk, receiver, 9090)))
        rows.append(("shared pod (default)", f"whoami backend {whoami_pod}", 80, "closed", lambda: p.pod(sk, whoami_pod, 80)))
        rows.append(("shared pod (default)", f"echo backend {echo_pod}", 7000, "closed", lambda: p.pod(sk, echo_pod, 7000)))
        rows.append(("receiver", "series pushed by shared", "-", "yes", lambda: pushed("shared")))
        rows.append(("shared pod", "routed IPv6 (global address, default route)", "-", "none", lambda: p.pod_ipv6(sk)))

    if args.acme:
        acme = outputs(args.tool, args.acme)
        root = acme["root_certificate"]

        def certificate(domain):
            """Whether the domain, reached through the entry point, presents a certificate for its
            name that chains to the test authority."""
            ctx = ssl.create_default_context(cadata=root)
            try:
                with socket.create_connection((public_ip, 443), timeout=10) as sock:
                    with ctx.wrap_socket(sock, server_hostname=domain):
                        return "valid"
            except ssl.SSLCertVerificationError as e:
                return "invalid: " + (e.verify_message or str(e))[:40]
            except OSError as e:
                return "error: " + str(e)[:40]

        def update(owner):
            """Adds then deletes a TXT record with the web tenant's key, from the web instance."""
            key = acme["certificates"]["web"]["dns"]["settings"]
            server, port = key["nameserver"].rsplit(":", 1)
            script = (f"server {server} {port}\nzone {acme['zone']}\nupdate add {owner}. 60 TXT isolation-probe\nsend\n"
                      f"update delete {owner}. TXT\nsend\n")
            cmd = (f"printf {shlex.quote(script)} | nsupdate -y "
                   f"{shlex.quote('hmac-sha256:' + key['tsig_key_name'] + ':' + key['tsig_secret'])} 2>&1; echo rc=$?")
            out = p.run(web["bastion"], web_vm[1], cmd)
            if out.endswith("rc=0"):
                return "accepted"
            return "refused" if "REFUSED" in out or "NOTAUTH" in out else "error: " + out[-60:]

        # The domains published through the entry point; the names of the shared cluster are
        # served on the internal services plane only (their certificate is checked by its consumer).
        # The Kubernetes tenant's domains only when it is deployed (--published-kubeconfig).
        for tenant, names in sorted(acme["tenants"].items()):
            if tenant == "shared" or (tenant != "web" and not args.published_kubeconfig):
                continue
            for d in names:
                rows.append(("test runner", f"{tenant} certificate of {d}", 443, "valid", lambda d=d: certificate(d)))
        own = acme["tenants"]["web"][0]
        rows.append((f"web {web_vm[0]}", f"TSIG update _acme-challenge.{own}", 53, "accepted",
                     lambda: update(f"_acme-challenge.{own}")))
        for tenant, names in sorted(acme["tenants"].items()):
            if tenant != "web":
                rows.append((f"web {web_vm[0]}", f"TSIG update _acme-challenge.{names[0]}", 53, "refused",
                             lambda n=names[0]: update(f"_acme-challenge.{n}")))

    failures = 0
    passed = {}  # source -> set of expected results that matched
    print(f"{'from':<22} {'to':<52} {'port':>5}  {'expected':<8} {'actual':<8}")
    for src, dst, port, expected, probe in rows:
        actual = probe()
        ok = actual == expected
        failures += 0 if ok else 1
        if ok:
            passed.setdefault(src.removesuffix(" (default)"), set()).add(expected)
        print(f"{src:<22} {dst:<52} {port:>5}  {expected:<8} {actual:<8} {'✅' if ok else '❌'}")
    print(f"\n{len(rows) - failures}/{len(rows)} rows as expected")

    # A closed result proves something only if the same source reaches what it should: a probe
    # that cannot connect at all would report every target closed.
    positive, negative = {"open", "yes", "valid", "accepted"}, {"closed", "refused", "no"}
    for src, results in sorted(passed.items()):
        if results & negative and not results & positive:
            print(f"❌ no positive control from {src}: its closed results prove nothing")
            failures += 1
    for kubectl in probe_pods:
        subprocess.run(kubectl + ["-n", "default", "delete", "pod", "isolation-probe", "--wait=false"], capture_output=True)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
