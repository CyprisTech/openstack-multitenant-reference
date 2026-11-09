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
        [--published-kubeconfig published.kubeconfig --internal-service tests/fixtures/internal-service] \
        [--acme tests/fixtures/acme] [--shared-kubeconfig shared.kubeconfig]

Requirements: the stacks shared/entry-point, tenants/vm and tenants/isolated applied with
bastions and pushing to the test receiver, and the receiver applied. With
--published-kubeconfig, the rows of the Kubernetes tenant are added: probes from the cluster run
in a short-lived pod, and the internal demonstration service must be applied. Probes only open
TCP connections and read the receiver; the only object created is the probe pod, deleted after
use.

With --shared-kubeconfig, the rows of the Kubernetes cluster for shared services are added
(stacks/shared/kubernetes, its demonstration services applied): the web tenant, its consumer,
reaches the internal ingress and the TCP echo; the other tenants do not; a pod of the cluster
reaches no tenant and, from another namespace, no backend of a service.

With --acme, the rows of the certificates are added (ADR-0008): each published domain, reached
through the entry point, presents a certificate for its name issued by the test authority, and
a tenant's TSIG key can change its own _acme-challenge records only (nsupdate on the web
instance; the record it adds is deleted at once).
"""

import argparse
import json
import os
import shlex
import socket
import ssl
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

    def pod(self, kubectl, target, port):
        """TCP probe run from a pod of the cluster."""
        r = subprocess.run(kubectl + ["-n", "default", "exec", "isolation-probe", "--", "sh", "-c",
                                      f"nc -z -w 5 {target} {port} && echo open || echo closed"],
                           capture_output=True, text=True, timeout=60)
        out = r.stdout.strip().splitlines()
        return out[-1] if out and out[-1] in ("open", "closed") else "error: " + (r.stderr.strip() or "kubectl failed")

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
    ap.add_argument("--user", default="ops")
    ap.add_argument("--published-kubeconfig")
    ap.add_argument("--kubectl", default="kubectl")
    ap.add_argument("--internal-service", default="tests/fixtures/internal-service")
    ap.add_argument("--key", required=True)
    ap.add_argument("--tool", default="tofu")
    ap.add_argument("--acme", help="directory of the test ACME authority (tests/fixtures/acme)")
    ap.add_argument("--shared-kubeconfig", help="kubeconfig of the cluster for shared services (stacks/shared/kubernetes)")
    args = ap.parse_args()

    edge = outputs(args.tool, os.path.join(args.stacks, "shared", "entry-point"))
    web = outputs(args.tool, os.path.join(args.stacks, "tenants", "vm"))
    iso = outputs(args.tool, os.path.join(args.stacks, "tenants", "isolated"))
    rcv = outputs(args.tool, args.receiver)
    p = Prober(args.user, args.key)

    edge_vm = sorted(edge["instances"].items())[0]
    web_vm = sorted(web["instances"].items())[0]
    iso_vm = sorted(iso["instances"].items())[0]
    public_ip = edge["load_balancer"]["floating_ip"]
    service = web["service_address"].split(":")[0]
    receiver = rcv["receiver_url"].split("//")[1].split(":")[0]

    def from_edge(target, port):
        return lambda: p.remote(edge["bastion"], edge_vm[1], target, port)

    def from_web(target, port):
        return lambda: p.remote(web["bastion"], web_vm[1], target, port)

    def from_iso(target, port):
        return lambda: p.remote(iso["bastion"], iso_vm[1], target, port)

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
    # Publication (ADR-0006): the entry point reaches the tenant's service address, and only it.
    rows.append(("test runner", "entry point (public IP)", 443, "open", lambda: p.local(public_ip, 443)))
    rows.append(("test runner", "entry point (public IP)", 80, "open", lambda: p.local(public_ip, 80)))
    rows.append(("test runner", f"web service address {service}", 443, "closed", lambda: p.local(service, 443)))
    rows.append((f"edge {edge_vm[0]}", f"web service address {service}", 443, "open", from_edge(service, 443)))
    rows.append((f"edge {edge_vm[0]}", f"web {web_vm[0]} (private {web_vm[1]})", 443, "closed", from_edge(web_vm[1], 443)))
    rows.append((f"isolated {iso_vm[0]}", f"web service address {service}", 443, "closed", from_iso(service, 443)))
    rows.append((f"web {web_vm[0]}", f"edge {edge_vm[0]} (private {edge_vm[1]})", 443, "closed", from_web(edge_vm[1], 443)))
    # Monitoring (ADR-0007): every tenant pushes to the receiver; nothing reaches a tenant's metrics.
    for name, probe in ((f"edge {edge_vm[0]}", from_edge), (f"web {web_vm[0]}", from_web), (f"isolated {iso_vm[0]}", from_iso)):
        rows.append((name, f"receiver {receiver}", 9090, "open", probe(receiver, 9090)))
    for name, ip in ((edge_vm[0], edge_vm[1]), (web_vm[0], web_vm[1]), (iso_vm[0], iso_vm[1])):
        rows.append(("receiver", f"{name} metrics (private {ip})", 9100, "closed", from_receiver(ip, 9100)))
    # Lateral movement (docs/concepts/architecture.md): a tenant or the entry point reaches the receiver on its port only,
    # and the receiver reaches neither a tenant's service address nor the entry point.
    for name, probe in ((f"edge {edge_vm[0]}", from_edge), (f"web {web_vm[0]}", from_web), (f"isolated {iso_vm[0]}", from_iso)):
        rows.append((name, f"receiver {receiver} (SSH)", 22, "closed", probe(receiver, 22)))
    rows.append(("receiver", f"web service address {service}", 443, "closed", from_receiver(service, 443)))
    rows.append(("receiver", f"edge {edge_vm[0]} (private {edge_vm[1]})", 443, "closed", from_receiver(edge_vm[1], 443)))
    for tenant in ("edge", "web", "isolated"):
        rows.append(("receiver", f"series pushed by {tenant}", "-", "yes", lambda t=tenant: pushed(t)))
    # Tenant to tenant, at the private addresses, and the isolated tenant's way out.
    rows.append((f"web {web_vm[0]}", f"isolated {iso_vm[0]} (private {iso_vm[1]})", 22, "closed", from_web(iso_vm[1], 22)))
    rows.append((f"isolated {iso_vm[0]}", f"web {web_vm[0]} (private {web_vm[1]})", 443, "closed", from_iso(web_vm[1], 443)))
    rows.append((f"isolated {iso_vm[0]}", "Internet (1.1.1.1)", 443, "closed", from_iso("1.1.1.1", 443)))

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
        api = kget(kubectl, "config", "view", "--minify", "-o", "jsonpath={.clusters[0].cluster.server}").split("//")[1].split(":")[0]
        internal = outputs(args.tool, args.internal_service)["address"]
        probe_pod = start_probe(args.published_kubeconfig)

        rows.append(("published Service", "ingress on the stack address", "-", "yes",
                     lambda: "yes" if svc_ingress == ingress else f"no: {svc_ingress}"))
        rows.append((f"edge {edge_vm[0]}", f"published ingress {ingress}", 443, "open", from_edge(ingress, 443)))
        rows.append(("test runner", f"published ingress {ingress}", 443, "closed", lambda: p.local(ingress, 443)))
        rows.append((f"web {web_vm[0]}", f"published ingress {ingress}", 443, "closed", from_web(ingress, 443)))
        rows.append((f"isolated {iso_vm[0]}", f"published ingress {ingress}", 443, "closed", from_iso(ingress, 443)))
        rows.append(("published pod", f"receiver {receiver}", 9090, "open", lambda: p.pod(probe_pod, receiver, 9090)))
        rows.append(("receiver", "series pushed by published", "-", "yes", lambda: pushed("published")))
        rows.append(("test runner (administrator)", f"published Kubernetes API {api}", 6443, "open", lambda: p.local(api, 6443)))
        for tenant, out in (("edge", edge), ("web", web), ("isolated", iso)):
            rows.append(("published pod", f"{tenant} bastion {out['bastion']} (SSH)", 22, "closed",
                         lambda b=out["bastion"]: p.pod(probe_pod, b, 22)))
        rows.append(("published pod", f"internal service {internal}", 8080, "open", lambda: p.pod(probe_pod, internal, 8080)))
        rows.append((f"web {web_vm[0]}", f"internal service {internal}", 8080, "closed", from_web(internal, 8080)))
        rows.append((f"isolated {iso_vm[0]}", f"internal service {internal}", 8080, "closed", from_iso(internal, 8080)))
        rows.append((f"edge {edge_vm[0]}", f"internal service {internal}", 8080, "closed", from_edge(internal, 8080)))
        rows.append(("receiver", f"internal service {internal}", 8080, "closed", from_receiver(internal, 8080)))
        rows.append(("receiver", f"published ingress {ingress}", 443, "closed", from_receiver(ingress, 443)))

    if args.shared_kubeconfig:
        # The cluster for shared services (spec: a Kubernetes cluster for shared services): the web
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
        rows.append((f"isolated {iso_vm[0]}", f"shared internal ingress {s_ingress}", 443, "closed", from_iso(s_ingress, 443)))
        rows.append((f"edge {edge_vm[0]}", f"shared internal ingress {s_ingress}", 443, "closed", from_edge(s_ingress, 443)))
        rows.append(("receiver", f"shared TCP echo {s_echo}", 7000, "closed", from_receiver(s_echo, 7000)))
        rows.append(("test runner", f"shared internal ingress {s_ingress}", 443, "closed", lambda: p.local(s_ingress, 443)))
        if probe_pod:
            rows.append(("published pod", f"shared internal ingress {s_ingress}", 443, "closed",
                         lambda: p.pod(probe_pod, s_ingress, 443)))
        rows.append(("shared pod", f"web {web_vm[0]} (private {web_vm[1]})", 443, "closed", lambda: p.pod(sk, web_vm[1], 443)))
        rows.append(("shared pod", f"web service address {service}", 443, "closed", lambda: p.pod(sk, service, 443)))
        for tenant, out in (("edge", edge), ("web", web), ("isolated", iso)):
            rows.append(("shared pod", f"{tenant} bastion {out['bastion']} (SSH)", 22, "closed",
                         lambda b=out["bastion"]: p.pod(sk, b, 22)))
        rows.append(("shared pod (default)", f"whoami backend {whoami_pod}", 80, "closed", lambda: p.pod(sk, whoami_pod, 80)))
        rows.append(("shared pod (default)", f"echo backend {echo_pod}", 7000, "closed", lambda: p.pod(sk, echo_pod, 7000)))
        rows.append(("receiver", "series pushed by shared", "-", "yes", lambda: pushed("shared")))

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
        for tenant, names in sorted(acme["tenants"].items()):
            if tenant == "shared":
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
    print(f"{'from':<22} {'to':<52} {'port':>5}  {'expected':<8} {'actual':<8}")
    for src, dst, port, expected, probe in rows:
        actual = probe()
        ok = actual == expected
        failures += 0 if ok else 1
        print(f"{src:<22} {dst:<52} {port:>5}  {expected:<8} {actual:<8} {'✅' if ok else '❌'}")
    print(f"\n{len(rows) - failures}/{len(rows)} rows as expected")
    for kubectl in probe_pods:
        subprocess.run(kubectl + ["-n", "default", "delete", "pod", "isolation-probe", "--wait=false"], capture_output=True)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
