"""The Kubernetes clusters of a campaign: kubectl, and the bootstrap instance that creates them."""

import json
import re
import time
from pathlib import Path

from .context import StepFailed

# The demonstration manifests name example.org: the names of the test instead.
EXAMPLE_ZONE = "example.org"


class Kubectl:
    """kubectl on one cluster, through its kubeconfig."""

    def __init__(self, ctx, kubeconfig):
        self.ctx = ctx
        self.kubeconfig = Path(kubeconfig)

    def __call__(self, *args, check=True, quiet=False, input=None, timeout=None):
        return self.ctx.runner.run(
            ["kubectl", "--kubeconfig", self.kubeconfig, *args], check=check, quiet=quiet, input=input, timeout=timeout
        )

    def out(self, *args, check=True):
        return self(*args, check=check, quiet=True).stdout.strip()

    def json(self, *args):
        """An object as JSON; {} in a dry run."""
        text = self.out(*args, "-o", "json")
        return json.loads(text) if text else {}

    def apply(self, manifest, *args):
        """Applies a manifest given as text (standard input)."""
        return self("apply", *args, "-f", "-", input=manifest)

    def show(self, *args):
        """A listing printed for the recordings and the results."""
        result = self(*args, check=False)
        if result.stdout.strip():
            self.ctx.runner.echo(result.stdout.rstrip())
        return result

    def cluster_name(self):
        """The name of the Cluster API cluster (cluster.name of the stack), read from the cluster."""
        return self.out("-n", "platform", "get", "cluster", "-o", "jsonpath={.items[0].metadata.name}") or "<cluster>"

    def node_names(self):
        return self.out("get", "nodes", "-o", "jsonpath={.items[*].metadata.name}").split()


def demo_manifest(ctx, path):
    """A demonstration manifest of a stack, with the zone of the test."""
    text = "" if ctx.runner.dry_run else (ctx.root / path).read_text()
    return text.replace(EXAMPLE_ZONE, ctx.config.get("test_zone", EXAMPLE_ZONE))


# --- the bootstrap instance ---------------------------------------------------------------------


def remote(ctx, host, command, check=True, quiet=False, stream=False, timeout=None):
    """A command on an instance the campaign reaches directly (the bootstrap instance). With
    `stream`, its output is printed as it comes: the cluster scripts run for many minutes."""
    cmd = ["ssh", "-F", ctx.ssh_config, host, command]
    return ctx.runner.run(cmd, check=check, quiet=quiet, timeout=timeout, stream=stream)


def copy(ctx, source, destination):
    return ctx.runner.run(["scp", "-F", ctx.ssh_config, "-q", source, destination])


def bootstrap_address(ctx, key):
    """The address of the bootstrap instance of a stack, or None (bootstrap = false, destroyed)."""
    try:
        value = ctx.value(key, "bootstrap")
    except Exception:  # a stack already destroyed has no output
        return None
    if ctx.runner.dry_run:
        return value
    return value if isinstance(value, str) and re.fullmatch(r"\d+(\.\d+){3}", value) else None


def wait_for_bootstrap(ctx, key):
    host = ctx.value(key, "bootstrap")
    status = remote(
        ctx, host, "cloud-init status --wait >/dev/null; s=$?; cloud-init status | tail -1; [ \"$s\" != 1 ]",
        check=False, quiet=True,
    )  # fmt: skip
    if not ctx.runner.dry_run:
        ctx.runner.echo(status.stdout.strip())
    if status.returncode != 0:
        raise StepFailed(f"bootstrap instance of {key} not ready: {status.stdout.strip()} {status.stderr.strip()}")


def install_credential(ctx, host, credential):
    """Puts a cluster credential on the bootstrap instance, where create-cluster.sh reads it."""
    copy(ctx, credential, f"{host}:/tmp/clouds.yaml")
    command = "sudo install -m 600 /tmp/clouds.yaml /opt/platform/clouds.yaml; rm -f /tmp/clouds.yaml"
    ca_cert = ctx.config.get("ca_cert")
    if ca_cert:
        copy(ctx, Path(ca_cert).expanduser(), f"{host}:/tmp/cacert.pem")
        command += "; sudo install -m 644 /tmp/cacert.pem /opt/platform/cacert.pem; rm -f /tmp/cacert.pem"
    remote(ctx, host, command, quiet=True)


def create_cluster(ctx, key, credential, kubeconfig):
    """Runs the creation script on the bootstrap instance, then fetches the kubeconfig."""
    host = ctx.value(key, "bootstrap")
    install_credential(ctx, host, credential)
    started = time.monotonic()
    result = remote(ctx, host, "sudo /opt/platform/create-cluster.sh", check=False, stream=True)
    write_log(ctx, f"create-cluster-{key}", result)
    ctx.timing(f"create-cluster {key} {round(time.monotonic() - started)}s")
    if result.returncode != 0:
        raise StepFailed(f"create-cluster.sh failed on {key} (log: logs/create-cluster-{key}.log)")
    fetch_kubeconfig(ctx, host, kubeconfig)
    kubectl = Kubectl(ctx, kubeconfig)
    kubectl.show("get", "nodes", "-o", "wide")
    kubectl.show("get", "svc", "-A", "--field-selector", "spec.type=LoadBalancer")
    return kubectl


def fetch_kubeconfig(ctx, host, kubeconfig):
    """The kubeconfig create-cluster.sh writes on the bootstrap instance, named after the cluster."""
    command = 'sudo sh -c "ls /opt/platform/*.kubeconfig | grep -v /bootstrap.kubeconfig | head -1 | xargs cat"'
    result = remote(ctx, host, command, quiet=True)
    if ctx.runner.dry_run:
        return
    if not result.stdout.strip():
        raise StepFailed(f"no kubeconfig on {host}")
    ctx.write_private(kubeconfig, result.stdout)


def delete_cluster(ctx, key, kubeconfig):
    """Admits the bootstrap instance on the API again, then deletes the cluster from it.

    Does nothing if the stack has no bootstrap instance. Once moved, the cluster manages itself:
    the bootstrap instance is admitted on its API first, with a patch of the API sources only
    (after an upgrade, cluster.yaml describes an older version). A creation that stopped before
    the move left Cluster API on the bootstrap instance: delete-cluster.sh deletes it from there.
    """
    host = bootstrap_address(ctx, key)
    if not host:
        ctx.runner.echo(f"{key}: no bootstrap instance, nothing to delete")
        return
    kubectl = Kubectl(ctx, kubeconfig)
    clusters = kubectl("--request-timeout=15s", "-n", "platform", "get", "cluster", "-o", "name", check=False, quiet=True)
    if clusters.returncode == 0 and clusters.stdout.strip():
        patch = json.dumps([{"op": "add", "path": "/spec/topology/variables/0/value/-", "value": f"{host}/32"}])
        for name in clusters.stdout.split():
            kubectl("-n", "platform", "patch", name, "--type=json", "-p", patch)
        ctx.sleep(60)
    started = time.monotonic()
    result = remote(ctx, host, "sudo /opt/platform/delete-cluster.sh", check=False, stream=True)
    write_log(ctx, f"delete-cluster-{key}", result)
    ctx.timing(f"delete-cluster {key} {round(time.monotonic() - started)}s")
    if result.returncode != 0:
        raise StepFailed(f"delete-cluster.sh failed on {key} (log: logs/delete-cluster-{key}.log)")


def write_log(ctx, name, result):
    if ctx.runner.dry_run:
        return
    logs = ctx.work / "logs"
    logs.mkdir(exist_ok=True)
    (logs / f"{name}.log").write_text(result.stdout + result.stderr)
