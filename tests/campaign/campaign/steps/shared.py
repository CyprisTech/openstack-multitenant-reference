"""The shared cluster (a Kubernetes cluster for shared services): created, tested, then removed."""

import base64
import json
import re
import threading
import time

from ..checks import isolation_test, kubeconfig, record
from ..context import StepFailed
from ..kube import Kubectl, copy, create_cluster, delete_cluster, demo_manifest, remote, update_cluster, wait_for_bootstrap
from ..load import Requests
from . import step
from .foundation import attachment, cluster_credential, monitoring, test_zone

STACK = "shared"

VOLUME_CHECK = """\
apiVersion: v1
kind: Namespace
metadata:
  name: volume-check
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: data
  namespace: volume-check
spec:
  serviceName: data
  replicas: 1
  selector:
    matchLabels: {app: data}
  template:
    metadata:
      labels: {app: data}
    spec:
      containers:
      - name: data
        image: busybox:1.37
        command: [sh, -c, "[ -f /data/marker ] || head -c 1048576 /dev/urandom > /data/marker; sleep infinity"]
        volumeMounts:
        - {name: data, mountPath: /data}
  volumeClaimTemplates:
  - metadata:
      name: data
    spec:
      accessModes: [ReadWriteOnce]
      resources:
        requests: {storage: 1Gi}
"""

ROTATION_VOLUME = """\
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: rotation-check
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests: {storage: 1Gi}
---
apiVersion: v1
kind: Pod
metadata:
  name: rotation-check
spec:
  containers:
  - name: check
    image: busybox:1.37
    command: [sh, -c, "date > /data/written; sleep infinity"]
    volumeMounts:
    - {name: data, mountPath: /data}
  volumes:
  - name: data
    persistentVolumeClaim: {claimName: rotation-check}
"""


def kubectl(ctx):
    return Kubectl(ctx, kubeconfig(ctx, STACK))


def service_name(ctx):
    return f"services.{test_zone(ctx)}"


def service_address(ctx):
    """The address of the internal ingress of the shared cluster."""
    return str(ctx.value(STACK, "services", "ingress")).split(":")[0]


def consumer_instance(ctx):
    """A tenant instance that consumes the shared services: the first instance of the vm stack."""
    return ctx.value("vm", "bastion"), ctx.instances("vm")[0]


def https_from_consumer(ctx, bastion, instance, address, extra=""):
    """HTTPS to the shared service from a tenant instance, with the root it received at boot."""
    name = service_name(ctx)
    command = f"curl -s{extra} --cacert /etc/lego/ca.pem --max-time 10 --resolve {name}:443:{address} https://{name}/"
    return ctx.on_instance(bastion, instance, command, check=False)


# --- steps -----------------------------------------------------------------------------------------


@step("k8s-shared")
def k8s_shared(ctx, report):
    ctx.set_inputs(
        STACK,
        cloud=ctx.cloud(STACK),
        plane_attachment=attachment(ctx, "k8s-shared"),
        monitoring=monitoring(ctx),
        consumers=ctx.value("vm", "internal_sources"),
        certificates=ctx.value("acme", "certificates", "shared"),
        bootstrap=True,
    )
    ctx.apply(STACK)
    wait_for_bootstrap(ctx, STACK)


@step("cluster-shared")
def cluster_shared(ctx, report):
    k = create_cluster(ctx, STACK, ctx.work / "shared-clouds.yaml", kubeconfig(ctx, STACK))
    deploy_demos(ctx, k)


@step("update-shared")
def update_shared(ctx, report):
    """The shared cluster after an apply of its stack: update-cluster.sh from the campaign host,
    then the demonstration services of this release."""
    deploy_demos(ctx, update_cluster(ctx, STACK, kubeconfig(ctx, STACK)))


def deploy_demos(ctx, k):
    k.apply(demo_manifest(ctx, f"{ctx.stack(STACK)}/demo/whoami.yaml"))
    k("apply", "-f", ctx.root / ctx.stack(STACK) / "demo/echo.yaml")
    k("-n", "whoami", "rollout", "status", "deploy/whoami", "--timeout=10m")
    k("-n", "echo", "rollout", "status", "deploy/echo", "--timeout=10m")


@step("tour-shared")
def tour_shared(ctx, report):
    k = kubectl(ctx)
    cmd = ["python3", "tests/tour/capture.py", "--kubeconfig", k.kubeconfig, "--cluster", k.cluster_name()]
    for replace in ctx.config.get("capture_replace", []):
        cmd += ["--replace", replace]
    result = ctx.runner.run(cmd, cwd=ctx.root, quiet=True)
    if not ctx.runner.dry_run:
        (ctx.work / "tour-shared.md").write_text(result.stdout)
    k.show("get", "nodes,svc", "-A")
    k.show("get", "gateway,httproute,certificate", "-A")
    k.show("get", "networkpolicy", "-A")


@step("accept-shared")
def accept_shared(ctx, report):
    """A consumer finds the service by its name in the zone, and reaches it over HTTPS with the
    root it received at boot (certificates.ca_bundle)."""
    address = service_address(ctx)
    bastion, instance = consumer_instance(ctx)
    name = service_name(ctx)
    dig = ctx.on_instance(bastion, instance, f"dig +short @{ctx.setting('name_server')} {name} A | tail -1")
    resolved = dig.stdout.strip()
    record(ctx, [f"{name} resolves to {resolved}"])
    if resolved != address and not ctx.runner.dry_run:
        raise StepFailed(f"{name} resolves to {resolved}, not {address}")
    if ctx.runner.dry_run:
        ctx.runner.echo(f"(6 requests to {name} from {instance})")
        isolation_test(ctx, report, "shared")
        return
    answers = []
    for _ in range(6):
        result = https_from_consumer(ctx, bastion, instance, address)
        hostname = [line for line in result.stdout.splitlines() if line.startswith("Hostname")]
        answers.append(hostname[0] if result.returncode == 0 and hostname else "FAIL")
    counts = {a: answers.count(a) for a in sorted(set(answers))}
    record(ctx, [f"shared https {n:>4} {a}" for a, n in counts.items()])
    report.measures["https shared"] = f"{6 - counts.get('FAIL', 0)}/6"
    if "FAIL" in counts and not ctx.runner.dry_run:
        raise StepFailed(f"{counts['FAIL']} of 6 requests to {name} failed")
    isolation_test(ctx, report, "shared")


def try_shared_service(ctx, address):
    """From this machine, through the consumer range of the scene."""
    name = service_name(ctx)
    cmd = ["curl", "-sS", "--cacert", ctx.work / "root.pem", "--max-time", "8",
           "--resolve", f"{name}:443:{address}", f"https://{name}/"]  # fmt: skip
    result = ctx.runner.run(cmd, check=False)
    ctx.runner.echo(f"curl exit={result.returncode}")
    return result.returncode == 0


def apply_manifests(ctx):
    manifests = ctx.value(STACK, "manifests")
    text = "" if ctx.runner.dry_run else manifests["addons.yaml"] + "\n---\n" + manifests["services.yaml"]
    kubectl(ctx).apply(text)


@step("consumer")
def consumer(ctx, report):
    """Closed by default, then a range of users admitted: consumer_cidr, this machine as the
    cluster sees it."""
    cidr = ctx.config.get("consumer_cidr")
    if not cidr:
        ctx.runner.echo("consumer_cidr not set: scene skipped")
        report.measures["consumer"] = "skipped"
        return
    address = service_address(ctx)
    with ctx.scene(STACK) as inputs:
        ctx.runner.echo("# Not a declared consumer: the service stays closed")
        if try_shared_service(ctx, address) and not ctx.runner.dry_run:
            raise StepFailed("open to an undeclared consumer")

        ctx.runner.echo("# Add a consumer: one line of configuration, apply, the two manifests")
        if not ctx.runner.dry_run:
            values = json.loads(inputs.read_text())
            values["consumers"] = list(values.get("consumers", [])) + [cidr]
            inputs.write_text(json.dumps(values, indent=2) + "\n")
        ctx.apply(STACK)
        apply_manifests(ctx)
        # The source reaches the chart, the Service, then the Octavia listeners: a minute or two.
        opened = None
        for attempt in range(1, 19):
            if try_shared_service(ctx, address):
                opened = attempt * 10
                break
            ctx.sleep(10)
        report.measures["consumer opened"] = f"{opened} s" if opened else "no"
        if opened is None and not ctx.runner.dry_run:
            raise StepFailed("the declared consumer is still refused after 3 minutes")
    ctx.runner.echo("# Back to the declared consumers")
    ctx.apply(STACK)
    apply_manifests(ctx)
    ctx.scene_done(STACK)


def volume_sum(ctx):
    return kubectl(ctx).out("-n", "volume-check", "exec", "data-0", "--", "sha256sum", "/data/marker").split(" ")[0]


@step("volume")
def volume(ctx, report):
    """A volume of the shared cluster keeps its data across the credential rotation and the
    upgrade. What is checked is the wiring of the landing zone (credential, zones), not Cinder."""
    k = kubectl(ctx)
    k.apply(VOLUME_CHECK)
    k("-n", "volume-check", "rollout", "status", "statefulset/data", "--timeout=10m")
    written = volume_sum(ctx)
    if not ctx.runner.dry_run:
        (ctx.work / "volume.sha256").write_text(written + "\n")
    k.show("-n", "volume-check", "get", "pvc,pod", "-o", "wide")
    record(ctx, [f"volume written: {written}"])


def volume_moved_intact(ctx, report, when):
    """The pod moves to another node: Cinder CSI detaches the volume and attaches it to the other
    node's server, with the credential it holds. The data read there must be the data written."""
    k = kubectl(ctx)
    node = "jsonpath={.spec.nodeName}"
    before = k.out("-n", "volume-check", "get", "pod", "data-0", "-o", node)
    k("cordon", before)
    k("-n", "volume-check", "delete", "pod", "data-0", "--wait=true")
    k("-n", "volume-check", "wait", "pod", "data-0", "--for=condition=Ready", "--timeout=10m")
    k("uncordon", before)
    after = k.out("-n", "volume-check", "get", "pod", "data-0", "-o", node)
    found = volume_sum(ctx)
    record(ctx, [f"volume {when}: moved from {before} to {after}, {found}"])
    if ctx.runner.dry_run:
        return
    written = (ctx.work / "volume.sha256").read_text().strip()
    if after == before or found != written:
        raise StepFailed(f"volume {when}: node {before} -> {after}, sum {found} (written {written})")
    report.measures[f"volume {when}"] = "intact"


def credential_of(ctx, path):
    """The application credential of a cluster credential file (never printed)."""
    import yaml  # noqa: PLC0415 (PyYAML, installed with the openstack client)

    auth = yaml.safe_load(path.read_text())["clouds"]["openstack"]["auth"]
    return auth["application_credential_id"], auth["application_credential_secret"]


def replace_secret_key(k, namespace, name, key, content):
    """Replaces a key of a Secret; the content goes through standard input, never printed."""
    secret = k.json("-n", namespace, "get", "secret", name)
    secret.setdefault("data", {})[key] = base64.b64encode(content.encode()).decode()
    for field in ("resourceVersion", "uid", "creationTimestamp", "managedFields"):
        secret.get("metadata", {}).pop(field, None)
    k.apply(json.dumps(secret))


@step("rotate")
def rotate(ctx, report):
    """Moves the cluster to another application credential, as in
    docs/guides/kubernetes-lifecycle.md, then checks the cloud controller and Cinder CSI with it.
    Cluster API uses it in the next step, once the old one is revoked."""
    k = kubectl(ctx)
    names = ctx.config.get("cluster_clouds", {})
    following = ctx.work / "next-clouds.yaml"
    cluster_credential(ctx, names.get("shared_next") or ctx.setting("cluster_clouds.shared_next"), following)
    identity = k.out("-n", "platform", "get", "openstackcluster", "-o", "jsonpath={.items[0].spec.identityRef.name}")

    ctx.runner.echo("# Cluster API: the secret of its identity")
    if not ctx.runner.dry_run:
        replace_secret_key(k, "platform", identity, "clouds.yaml", following.read_text())

    ctx.runner.echo("# Cloud controller manager and Cinder CSI: their configuration, then a restart")
    if not ctx.runner.dry_run:
        credential_id, secret = credential_of(ctx, following)
        encoded = k.out("-n", "kube-system", "get", "secret", "cloud-config", "-o", r"jsonpath={.data.cloud\.conf}")
        conf = base64.b64decode(encoded).decode()
        conf = re.sub(r"(?m)^application-credential-id=.*$", f"application-credential-id={credential_id}", conf)
        conf = re.sub(r"(?m)^application-credential-secret=.*$", f"application-credential-secret={secret}", conf)
        replace_secret_key(k, "kube-system", "cloud-config", "cloud.conf", conf)
    workloads = [w for w in k.out("-n", "kube-system", "get", "deployment,daemonset", "-o", "name").split()
                 if re.search("cloud-controller|csi", w)]  # fmt: skip
    for workload in workloads:
        k("-n", "kube-system", "rollout", "restart", workload)
    for workload in workloads:
        k("-n", "kube-system", "rollout", "status", workload, "--timeout=10m")

    ctx.runner.echo("# The bootstrap instance deletes the cluster later: it needs the new credential too")
    host = ctx.value(STACK, "bootstrap")
    if host:
        copy(ctx, following, f"{host}:/tmp/clouds.yaml")
        remote(ctx, host, "sudo install -m 600 /tmp/clouds.yaml /opt/platform/clouds.yaml; rm -f /tmp/clouds.yaml", quiet=True)

    ctx.runner.echo("# A load balancer created with the new credential")
    # Internal: without an annotation, the cloud controller picks an external network for the
    # floating IP by itself, which the cluster may not reach.
    k.apply(json.dumps({
        "apiVersion": "v1", "kind": "Service",
        "metadata": {"name": "rotation-check", "namespace": "default",
                     "annotations": {"service.beta.kubernetes.io/openstack-internal-load-balancer": "true"}},
        "spec": {"type": "LoadBalancer", "selector": {"app": "rotation-check"},
                 "ports": [{"name": "80-80", "port": 80, "targetPort": 80, "protocol": "TCP"}]},
    }))  # fmt: skip
    k("-n", "default", "wait", "service/rotation-check", "--for=jsonpath={.status.loadBalancer.ingress[0].ip}", "--timeout=10m")
    k("-n", "default", "delete", "service", "rotation-check")
    k("-n", "default", "wait", "service/rotation-check", "--for=delete", "--timeout=10m")

    ctx.runner.echo("# Cinder CSI with the new credential: a new volume, and the existing one moved intact")
    k.apply(ROTATION_VOLUME, "-n", "volume-check")
    k("-n", "volume-check", "wait", "pod", "rotation-check", "--for=condition=Ready", "--timeout=10m")
    k("-n", "volume-check", "delete", "pod", "rotation-check", "--wait=true")
    k("-n", "volume-check", "delete", "pvc", "rotation-check", "--wait=true")
    volume_moved_intact(ctx, report, "after the rotation")

    old = names.get("shared") or ctx.setting("cluster_clouds.shared")
    ctx.runner.echo(f"# Revoke the old credential ({old}): the upgrade waits for it")
    wait_for_revocation(ctx, old)


def wait_for_revocation(ctx, cloud, attempts=90, delay=20):
    """The upgrade proves the new credential only once the old one no longer authenticates.
    Revoking it needs rights the campaign does not have: waits for an administrator, 30 minutes."""
    ctx.notify(
        f"⚠️ Action: revoke the old application credential {cloud} now. The rotation is done; the upgrade "
        "starts once the old credential no longer authenticates (30 minutes at most)."
    )
    if ctx.runner.dry_run:
        return
    for attempt in range(attempts):
        token = ctx.runner.run(["openstack", "--os-cloud", cloud, "token", "issue", "-f", "value", "-c", "id"],
                               check=False, quiet=True)
        if token.returncode != 0:
            ctx.runner.echo("the old credential no longer authenticates")
            return
        if attempt % 6 == 0:
            ctx.runner.echo(f"{time.strftime('%H:%M:%S', time.gmtime())} waiting for the revocation of {cloud}")
        ctx.sleep(delay)
    raise StepFailed(f"old credential {cloud} still valid after {attempts * delay // 60} minutes")


class ConsumerLoad(Requests):
    """Requests from a tenant instance to the shared service, every 2 s, until stopped."""

    label = "shared service"

    def __init__(self, ctx, bastion, instance, address):
        self.args = (ctx, bastion, instance, address)
        self.ok = self.failed = 0
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._run, daemon=True)

    def start(self):
        if not self.args[0].runner.dry_run:
            self.started()
            self._thread.start()

    def stop(self):
        self._stop.set()
        if self._thread.is_alive():
            self._thread.join()
        self.stopped()

    def _run(self):
        while not self._stop.is_set():
            result = https_from_consumer(*self.args, extra="f -o /dev/null")
            if result.returncode == 0:
                self.ok += 1
            else:
                self.failed += 1
            time.sleep(2)


@step("upgrade")
def upgrade(ctx, report):
    """A minor upgrade by Cluster API, with the commands of the guide. The addresses must not
    change and the service must answer during and after it."""
    k = kubectl(ctx)
    settings = ctx.config.get("upgrade", {})
    version = settings.get("version") or ctx.setting("upgrade.version")
    image = settings.get("image") or ctx.setting("upgrade.image")
    cluster = k.cluster_name()
    image_object = re.sub(r"[.]", "-", image.lower())
    server = "jsonpath={.clusters[0].cluster.server}"
    api = k.out("config", "view", "--minify", "-o", server)
    address = service_address(ctx)
    bastion, instance = consumer_instance(ctx)
    k.show("get", "nodes")

    ctx.runner.echo("# The image of the new version, then the version")
    images = k.json("-n", "platform", "get", "image.openstack.k-orc.cloud").get("items", [{}])
    current = images[0] if images else {}
    spec = json.loads(json.dumps(current.get("spec", {})))
    spec.setdefault("import", {}).setdefault("filter", {})["name"] = image
    k.apply(json.dumps({
        "apiVersion": current.get("apiVersion", "openstack.k-orc.cloud/v1alpha1"), "kind": current.get("kind", "Image"),
        "metadata": {"name": image_object, "namespace": current.get("metadata", {}).get("namespace", "platform")},
        "spec": spec,
    }))  # fmt: skip
    k("-n", "platform", "wait", "image.openstack.k-orc.cloud", image_object, "--for=condition=Available", "--timeout=10m")
    patch = json.dumps([
        {"op": "replace", "path": "/spec/topology/version", "value": version},
        {"op": "replace", "path": "/spec/topology/variables/1/value", "value": image_object},
    ])  # fmt: skip
    k("-n", "platform", "patch", "cluster", cluster, "--type=json", "-p", patch)

    # Requests from a consumer during the upgrade: measured, kept for the results.
    load = ConsumerLoad(ctx, bastion, instance, address)
    load.start()
    done = False
    try:
        for _ in range(180 if not ctx.runner.dry_run else 1):
            # The API may time out while a control plane machine is replaced: next round.
            listing = k("get", "nodes", "--no-headers", "--request-timeout=15s", check=False, quiet=True)
            machines = k("-n", "platform", "get", "machines", "--no-headers", "--request-timeout=15s", check=False, quiet=True)
            if listing.returncode == 0 and machines.returncode == 0 and not ctx.runner.dry_run:
                nodes = [line.split() for line in listing.stdout.splitlines() if line.strip()]
                ready = [n for n in nodes if n[1] == "Ready" and n[-1] == version]
                expected = len([line for line in machines.stdout.splitlines() if line.strip()])
                now = time.strftime("%H:%M:%S", time.gmtime())
                ctx.runner.echo(f"{now} nodes {len(nodes)}, ready at {version}: {len(ready)}")
                if len(ready) == expected == len(nodes):
                    done = True
                    break
            ctx.sleep(20)
    finally:
        load.stop()
    record(ctx, [f"requests during the upgrade: {load.summary()}"])
    report.measures["upgrade load"] = load.summary()
    if not done and not ctx.runner.dry_run:
        raise StepFailed(f"the nodes did not all reach {version} in an hour")
    k.show("get", "nodes")

    ctx.runner.echo("# The addresses did not change, the service answers")
    k("get", "--raw", "/readyz", quiet=True)
    ingress = k.out("-n", "traefik-internal", "get", "svc", "-o", "jsonpath={.items[0].status.loadBalancer.ingress[0].ip}")
    if not ctx.runner.dry_run:
        if k.out("config", "view", "--minify", "-o", server) != api:
            raise StepFailed("the address of the Kubernetes API changed")
        if not ingress:
            raise StepFailed("the internal ingress has no address")
        if service_address(ctx) != address:
            raise StepFailed("the address of the shared service changed")
    accept_shared(ctx, report)

    ctx.runner.echo("# The volume followed its pod to a new node, intact")
    volume_moved_intact(ctx, report, "after the upgrade")


@step("shared-down")
def shared_down(ctx, report):
    # The volumes of the check are deleted while Cinder CSI still runs, or they would be left behind.
    kubectl(ctx)("--request-timeout=30s", "delete", "namespace", "volume-check", "--wait=true", "--timeout=10m", check=False)
    delete_cluster(ctx, STACK, kubeconfig(ctx, STACK))
    ctx.destroy(STACK)
