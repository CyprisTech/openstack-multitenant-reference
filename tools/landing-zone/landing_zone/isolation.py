"""The rows of the isolation test, produced from the members of a deployment (lz check, #41).

A member is what the configuration declares (a tenant, a shared service, the entry point) with the
facts its stack gives: its instances and their bastion, its service address, the services it offers.
The rules below turn them into rows: a source, a target address and port, the expected result and
the rule that expects it. They hold for any deployment: the reference scenario is one of them.

A source is how a probe runs: from the machine running lz ("local"), or from an instance through the
bastion of its stack ("ssh"). A member without instances (a cluster, a project of type existing that
declares no access) is a target only.
"""

from dataclasses import dataclass, field


@dataclass
class Member:
    name: str
    role: str  # "entry-point", "tenant", "service"
    planes: dict  # plane -> role on it ("tenant" or "shared")
    instances: dict = field(default_factory=dict)  # name -> private address
    bastion: str | None = None
    service_address: str | None = None  # behind the entry point: the address it routes to
    services: dict = field(default_factory=dict)  # name -> ["address:port", ...], on the internal plane
    consumers: list = field(default_factory=list)  # the members admitted to its services
    egress: str | None = None  # "router", "shared", "none"
    public_address: str | None = None  # the entry point's address on the Internet

    def source(self):
        """How a probe runs from this member, or None (a target only)."""
        if not self.instances or not self.bastion:
            return None
        name, address = sorted(self.instances.items())[0]
        return {"kind": "ssh", "jump": self.bastion, "host": address, "label": f"{self.name} {name}"}

    def first_instance(self):
        return sorted(self.instances.items())[0] if self.instances else None


LOCAL = {"kind": "local", "label": "test runner"}


def row(source, target, port, expected, rule):
    return {"source": source, "target": target, "port": port, "expected": expected, "rule": rule}


def target(address, label):
    return {"address": address, "label": label}


def rows(members, receiver=None, public_probe="1.1.1.1"):
    """Every row the rules expect of these members. receiver: "host:port" of the metrics receiver
    on the observability plane, or None."""
    entry = next((m for m in members if m.role == "entry-point"), None)
    out = []
    out += publication(entry, members)
    out += between_members(members)
    out += internal_services(entry, members)
    if receiver:
        out += observability(members, receiver)
    out += way_out(members, public_probe)
    # A source that reaches nothing it should proves nothing by its closed results (a probe that
    # cannot connect at all would report every target closed): it stays a target only.
    controlled = {r["source"]["label"] for r in out if r["expected"] == "open"}
    unique, seen = [], set()
    for r in out:  # two rules may expect the same row: probed once, under the first
        key = (r["source"]["label"], r["target"]["address"], r["port"])
        if r["source"]["label"] in controlled and key not in seen:
            seen.add(key)
            unique.append(r)
    return unique


def publication(entry, members):
    """The entry point is reached from the Internet; it alone reaches the service addresses of the
    tenants it publishes, and none of their instances."""
    if entry is None or not entry.public_address:
        return []
    out = [row(LOCAL, target(entry.public_address, "entry point (public IP)"), port, "open", "publication")
           for port in (443, 80)]  # fmt: skip
    for m in members:
        if m.role != "tenant" or not m.service_address or "publication" not in m.planes:
            continue
        address = target(m.service_address, f"{m.name} service address {m.service_address}")
        out.append(row(LOCAL, address, 443, "closed", "publication"))
        if entry.source():
            out.append(row(entry.source(), address, 443, "open", "publication"))
            if m.first_instance():
                name, ip = m.first_instance()
                out.append(row(entry.source(), target(ip, f"{m.name} {name} (private {ip})"), 443, "closed", "publication"))
    return out


def between_members(members):
    """No member reaches another: neither its instances nor its service address, unless it is one
    of the consumers of a service the other offers (the rule of internal services)."""
    out = []
    for a in members:
        if not a.source():
            continue
        for b in members:
            if b is a or b.role == "entry-point" and a.role != "tenant":
                continue
            if b.first_instance():
                name, ip = b.first_instance()
                to = target(ip, f"{b.name} {name} (private {ip})")
                for port in instance_ports(b):
                    out.append(row(a.source(), to, port, "closed", "between members"))
            if b.service_address and a.role != "entry-point":
                address = target(b.service_address, f"{b.name} service address {b.service_address}")
                out.append(row(a.source(), address, 443, "closed", "between members"))
    return out


def instance_ports(member):
    """The ports probed on a member's instance: SSH, and HTTPS when it serves the entry point or is it,
    and the ports of the services it offers."""
    ports = [22]
    if member.service_address or member.role == "entry-point":
        ports.append(443)
    for entries in member.services.values():
        ports += [int(e.rsplit(":", 1)[1]) for e in entries]
    return sorted(set(ports))


def internal_services(entry, members):
    """A shared service admits its consumers on its ports, and nobody else on the internal services
    plane; neither the entry point nor the machine running the test reaches it."""
    out = []
    for s in members:
        for name, entries in s.services.items():
            for endpoint in entries:
                address, port = endpoint.rsplit(":", 1)
                to = target(address, f"{s.name} {name} {address}")
                out.append(row(LOCAL, to, int(port), "closed", "internal services"))
                for m in members:
                    if m is s or not m.source():
                        continue
                    if m.name in s.consumers:
                        out.append(row(m.source(), to, int(port), "open", "internal services"))
                    elif "internal" in m.planes or m.role == "entry-point":
                        out.append(row(m.source(), to, int(port), "closed", "internal services"))
    return out


def observability(members, receiver):
    """Every member on the observability plane reaches the receiver's push port."""
    host, port = receiver.rsplit(":", 1)
    return [row(m.source(), target(host, f"receiver {host}"), int(port), "open", "observability")
            for m in members if m.source() and "observability" in m.planes]  # fmt: skip


def way_out(members, public_probe):
    """A member without egress reaches no address on the Internet."""
    return [row(m.source(), target(public_probe, f"Internet ({public_probe})"), 443, "closed", "the way out")
            for m in members if m.source() and m.egress == "none"]  # fmt: skip
