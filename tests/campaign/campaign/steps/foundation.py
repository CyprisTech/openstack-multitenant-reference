"""The foundation: credentials, planes, test fixtures, entry point, tenants without Kubernetes."""

import os
import subprocess
import threading
import time
from pathlib import Path

from ..context import StepFailed
from . import step

# The application credentials handed to the clusters: a clouds.yaml entry renamed openstack.
CLUSTER_CREDENTIALS = {"published": "published-clouds.yaml", "shared": "shared-clouds.yaml"}


# --- inputs the stacks give each other -------------------------------------------------------------


def attachment(ctx, name):
    """The planes of an attachment, from the output of the planes stack."""
    return ctx.value("planes", "attachments", name, "planes")


def monitoring(ctx):
    return {"receiver": ctx.value("receiver", "receiver_url")}


def edge_sources(ctx):
    return ctx.value("entry-point", "publication_sources")


def test_zone(ctx):
    return ctx.config.get("test_zone", "example.org")


def root_certificate(ctx):
    """The root of the test ACME authority, written by step acme; none without the fixture."""
    path = ctx.work / "root.pem"
    return path if ctx.has("acme") else None


# --- steps -----------------------------------------------------------------------------------------


@step("prep")
def prep(ctx, report):
    """The credentials of the clusters, and the SSH configuration of the campaign."""
    names = ctx.config.get("cluster_clouds", {})
    for key, file in CLUSTER_CREDENTIALS.items():
        if ctx.has(key):
            cluster_credential(ctx, names.get(key) or ctx.setting(f"cluster_clouds.{key}"), ctx.work / file)
    ctx.write_private(
        ctx.ssh_config,
        "Host *\n"
        f"  User {ctx.setting('ssh_user')}\n"
        f"  IdentityFile {os.path.expanduser(ctx.setting('ssh_key'))}\n"
        "  StrictHostKeyChecking no\n"
        "  UserKnownHostsFile /dev/null\n"
        "  LogLevel ERROR\n",
    )


def cluster_credential(ctx, entry, path):
    """Copies a clouds.yaml entry, renamed openstack, for a cluster. Its content is never printed.

    clouds.yaml is YAML: PyYAML, installed with the openstack client, reads it.
    """
    ctx.runner.echo(f"cluster credential: {entry} -> {path.name}")
    if ctx.runner.dry_run:
        return
    import yaml  # noqa: PLC0415 (only this step reads YAML)

    source = Path(ctx.config.get("clouds_yaml", "~/.config/openstack/clouds.yaml")).expanduser()
    clouds = yaml.safe_load(source.read_text())["clouds"]
    if entry not in clouds:
        raise StepFailed(f"{source}: no entry {entry}")
    credential = dict(clouds[entry])
    if credential.pop("cacert", None):
        credential["cacert"] = "/opt/platform/cacert.pem"  # where create-cluster.sh installs it
    ctx.write_private(path, yaml.safe_dump({"clouds": {"openstack": credential}}))


@step("planes")
def planes(ctx, report):
    """The planes of the mode, and an attachment per stack of the scenario that has one."""
    planes = ctx.config.get("planes", {}).get(ctx.mode)
    if planes is None:
        if not ctx.runner.dry_run:
            raise StepFailed(f"campaign.local.toml has no [planes.{ctx.mode}]")
        planes = f"<planes.{ctx.mode}>"
    options = ctx.options.get("planes", {})
    attachments = {}
    for name, spec in options.get("attachments", {}).items():
        if ctx.has(spec["stack"]):
            attachments[name] = {"project_id": ctx.project_id(spec["stack"]), "cidr": spec["cidr"], "planes": spec["planes"]}
    ctx.set_inputs(
        "planes",
        cloud=ctx.cloud("planes"),
        site=ctx.setting("site"),
        planes=planes,
        attachments=attachments,
        tenant_ranges=options.get("tenant_ranges", {}),
    )
    ctx.apply("planes")
    report.measures["attachments"] = len(attachments)


@step("receiver")
def receiver(ctx, report):
    ctx.set_inputs("receiver", plane_attachment=attachment(ctx, "receiver"))
    ctx.apply("receiver")
    ctx.wait_for_instances(ctx.value("receiver", "bastion"), [ctx.value("receiver", "address")])


@step("acme")
def acme(ctx, report):
    ctx.set_inputs("acme", plane_attachment=attachment(ctx, "acme"))
    ctx.apply("acme")
    root = ctx.value("acme", "root_certificate")
    if not ctx.runner.dry_run:
        (ctx.work / "root.pem").write_text(root)
    ctx.wait_for_instances(ctx.value("acme", "bastion"), [ctx.value("acme", "instance_address")])


@step("internal")
def internal(ctx, report):
    """The fixture of an internal service, created before its consumers, closed: it admits
    nobody until step internal-open."""
    ctx.set_inputs(
        "internal-service",
        cloud=ctx.cloud("internal-service"),
        plane_attachment=attachment(ctx, "internal-service"),
        allowed_sources=[],
    )
    ctx.apply("internal-service")


@step("edge")
def edge(ctx, report):
    """The entry point, with no domain yet (step publish publishes them)."""
    domains = ctx.root / ctx.stack("entry-point") / "domains.auto.tfvars.json"
    if not ctx.runner.dry_run:
        domains.unlink(missing_ok=True)
    ctx.set_inputs(
        "entry-point", cloud=ctx.cloud("entry-point"), plane_attachment=attachment(ctx, "edge"), monitoring=monitoring(ctx)
    )
    ctx.apply("entry-point")
    ctx.wait_for_instances(ctx.value("entry-point", "bastion"), ctx.instances("entry-point"))


@step("web")
def web(ctx, report):
    inputs = dict(
        cloud=ctx.cloud("vm"),
        plane_attachment=attachment(ctx, "web"),
        monitoring=monitoring(ctx),
        edge_sources=edge_sources(ctx),
    )
    # Without the test ACME authority, the tenant keeps its demonstration certificates (ADR-0008).
    if ctx.has("acme"):
        inputs["certificates"] = ctx.value("acme", "certificates", "web")
    ctx.set_inputs("vm", **inputs)
    ctx.apply("vm")
    ctx.wait_for_instances(ctx.value("vm", "bastion"), ctx.instances("vm"))


@step("isolated")
def isolated(ctx, report):
    ctx.set_inputs(
        "isolated", cloud=ctx.cloud("isolated"), plane_attachment=attachment(ctx, "isolated"), monitoring=monitoring(ctx)
    )
    ctx.apply("isolated")
    ctx.wait_for_instances(ctx.value("isolated", "bastion"), ctx.instances("isolated"))


@step("transit")
def transit(ctx, report):
    """The planes again: the routes of the transit routers follow the attachments (ADR-0013)."""
    ctx.apply("planes")
    ctx.runner.echo(f"transit: {ctx.value('planes', 'transit')}")


@step("publish")
def publish(ctx, report, load=None):
    """The domains of the tenants on the entry point. After the first publication, new domains
    are published under load: no request may fail."""
    marker = ctx.work / "published-once"
    if load is None:
        load = marker.exists() and ctx.options.get("publish", {}).get("load", True)
    loader = Load(ctx) if load and not ctx.runner.dry_run else None
    if load and ctx.runner.dry_run:
        ctx.runner.echo("(load on site-a during the publication)")
    if loader:
        loader.start()
    env = dict(os.environ, OS_CLOUD=ctx.cloud("entry-point"))
    try:
        result = ctx.runner.run(["scripts/publish-domains.sh", "--tool", ctx.tool], cwd=ctx.root, env=env, check=False)
        if result.stdout.strip():
            ctx.runner.echo(result.stdout.strip())
    finally:
        if loader:
            loader.stop()
    if not ctx.runner.dry_run:
        marker.touch()
    if loader:
        report.measures["load"] = f"{loader.ok} ok, {loader.failed} failed"
        with (ctx.work / "https.txt").open("a") as f:
            f.write(f"requests during the publication: {loader.ok} ok, {loader.failed} failed\n")
    if result.returncode != 0:
        raise StepFailed(f"publish-domains.sh failed:\n{result.stderr.strip()}")
    if loader and loader.failed:
        raise StepFailed(f"{loader.failed} requests failed during the publication")


class Load:
    """HTTPS requests on site-a through the entry point, every 0.2 s, until stopped."""

    def __init__(self, ctx):
        self.ctx = ctx
        self.ok = self.failed = 0
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._run, daemon=True)

    def start(self):
        self.address = self.ctx.value("entry-point", "load_balancer", "floating_ip")
        self._thread.start()

    def stop(self):
        self._stop.set()
        self._thread.join()

    def _run(self):
        domain = f"site-a.{test_zone(self.ctx)}"
        root = root_certificate(self.ctx)
        trust = ["--cacert", str(root)] if root else ["--insecure"]
        cmd = ["curl", "-sf", "-o", "/dev/null", *trust, "--max-time", "5",
               "--resolve", f"{domain}:443:{self.address}", f"https://{domain}/"]  # fmt: skip
        while not self._stop.is_set():
            if subprocess.run(cmd, check=False).returncode == 0:
                self.ok += 1
            else:
                self.failed += 1
            time.sleep(0.2)
