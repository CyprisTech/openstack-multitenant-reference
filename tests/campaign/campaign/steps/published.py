"""The published cluster behind the entry point, and the acceptance scenes of the tenants."""

import json

from ..checks import https_probe, isolation_test, kubeconfig, record, wait_https
from ..context import StepFailed
from ..kube import Kubectl, create_cluster, demo_manifest, update_cluster, wait_for_bootstrap
from . import step
from .foundation import attachment, edge_sources, monitoring, publish, test_zone, transit

STACK = "published"


def kubectl(ctx):
    return Kubectl(ctx, kubeconfig(ctx, STACK))


def entry_address(ctx):
    """The public address of the entry point (its load balancer's floating IP)."""
    return ctx.value("entry-point", "load_balancer", "floating_ip")


def service_address(ctx, key):
    return str(ctx.value(key, "service_address")).split(":")[0]


def domains(ctx, *names):
    return [f"{name}.{test_zone(ctx)}" for name in names]


def edit_inputs(ctx, path, change):
    """Changes the inputs of a stack inside a scene (the scene restores them)."""
    if ctx.runner.dry_run:
        return
    values = json.loads(path.read_text())
    change(values)
    path.write_text(json.dumps(values, indent=2) + "\n")


def reachable(ctx, bastion, instance, target, port=443):
    """A TCP connection from an instance to target:port succeeds."""
    command = f"timeout 4 bash -c '</dev/tcp/{target}/{port}'"
    return ctx.on_instance(bastion, instance, command, check=False).returncode == 0 and not ctx.runner.dry_run


def entry_point_instance(ctx):
    return ctx.value("entry-point", "bastion"), ctx.instances("entry-point")[0]


def deploy_demo(ctx):
    k = kubectl(ctx)
    k.apply(demo_manifest(ctx, f"{ctx.stack(STACK)}/demo/whoami.yaml"))
    k("-n", "demo", "rollout", "status", "deploy/whoami", "--timeout=10m")


def ingress_address(ctx):
    # The Service may not exist yet: an empty address, waited for by the caller.
    return kubectl(ctx).out(
        "-n", "traefik", "get", "svc", "traefik", "-o", "jsonpath={.status.loadBalancer.ingress[0].ip}", check=False
    )


# --- steps -----------------------------------------------------------------------------------------


@step(
    "k8s",
    guide=[
        "docs/reference/test-procedure.md#7-published-cluster",
        "stacks/tenants/kubernetes/README.md#usage",
    ],
)
def k8s(ctx, report):
    ctx.set_inputs(
        STACK,
        cloud=ctx.cloud(STACK),
        plane_attachment=attachment(ctx, "published"),
        monitoring=monitoring(ctx),
        edge_sources=edge_sources(ctx),
        certificates=ctx.value("acme", "certificates", "published"),
        bootstrap=True,
    )
    ctx.apply(STACK)
    wait_for_bootstrap(ctx, STACK)


@step(
    "cluster",
    guide=[
        "docs/reference/test-procedure.md#7-published-cluster",
        "stacks/tenants/kubernetes/README.md#usage",
    ],
)
def cluster(ctx, report):
    create_cluster(ctx, STACK, ctx.work / "published-clouds.yaml", kubeconfig(ctx, STACK))


@step(
    "internal-open",
    guide=[
        "docs/reference/test-procedure.md#open-the-internal-service",
        "docs/guides/open-a-service.md#an-internal-service",
    ],
)
def internal_open(ctx, report):
    """The internal service, created closed in the foundation (step internal), is opened to the
    Kubernetes tenant once it exists: a change of its consumers, in place."""
    ctx.set_inputs(
        "internal-service",
        cloud=ctx.cloud("internal-service"),
        plane_attachment=attachment(ctx, "internal-service"),
        allowed_sources=ctx.value(STACK, "internal_sources"),
    )
    ctx.apply("internal-service")


@step("tour", guide="docs/guides/kubernetes-tour.md")
def tour(ctx, report):
    k = kubectl(ctx)
    name = k.cluster_name()
    cmd = ["python3", "tests/tour/capture.py", "--kubeconfig", k.kubeconfig, "--cluster", name]
    for replace in ctx.config.get("capture_replace", []):
        cmd += ["--replace", replace]
    result = ctx.runner.run(cmd, cwd=ctx.root, quiet=True)
    if not ctx.runner.dry_run:
        (ctx.work / "kubernetes-tour.md").write_text(result.stdout)
    described = ctx.runner.run(
        ["clusterctl", "describe", "cluster", name, "-n", "platform", "--kubeconfig", k.kubeconfig], check=False
    )
    if described.stdout.strip():
        ctx.runner.echo(described.stdout.rstrip())
    k.show("get", "machines", "-n", "platform")
    k.show("get", "gateway,httproute,certificate", "-A")


@step(
    "accept",
    guide=[
        "docs/reference/test-procedure.md#9-acceptance",
        "docs/getting-started/README.md#7-check",
        "docs/guides/check-isolation.md#run",
        "stacks/tenants/kubernetes/README.md#checks",
        "stacks/tenants/kubernetes/README.md#certificates",
    ],
)
def accept(ctx, report):
    """HTTPS through the entry point to the domains, then the isolation test."""
    names = ["site-a", "site-b"]
    if ctx.has(STACK):
        deploy_demo(ctx)
        for _ in range(60):
            if ingress_address(ctx) or ctx.runner.dry_run:
                break
            ctx.sleep(10)
        ctx.sleep(30)  # the routes reach Traefik within seconds; the agents push every 30 s
        names.append("apps.published")
    address = entry_address(ctx)
    for domain in domains(ctx, *names):
        https_probe(ctx, report, domain, address)
    isolation_test(ctx, report, STACK if ctx.has(STACK) else None)


@step("direct", guide="docs/reference/test-procedure.md#direct-exposure")
def direct(ctx, report):
    """The vm tenant exposed directly (exposure = "public"): HTTPS on its own public address, no
    router on the publication plane, the entry point no longer reaches its instances. Then back
    to the entry point."""
    failures = []
    with ctx.scene("vm") as inputs:
        edit_inputs(ctx, inputs, lambda v: v.update(exposure="public"))
        ctx.apply("vm", empty_plan=False)
        address = service_address(ctx, "vm")
        record(ctx, [f"service address, exposed directly: {address}"])
        try:
            https_probe(ctx, report, domains(ctx, "site-a")[0], address)
        except StepFailed as error:
            failures.append(str(error))
        else:
            ctx.runner.echo("# No router on the publication plane: the entry point no longer reaches the instances")
            bastion, edge = entry_point_instance(ctx)
            instance = ctx.instances("vm")[0]
            if reachable(ctx, bastion, edge, instance):
                failures.append(f"the entry point still reaches {instance}")
            else:
                record(ctx, [f"entry point -> {instance}:443 closed"])
    back_to_entry_point(ctx, report, "vm", ["site-a", "site-b"], failures)


def back_to_entry_point(ctx, report, key, names, failures, after_apply=None, load=False):
    """The scene restored: apply, transit routes, publication, then HTTPS steady through the
    entry point. The load balancer existed before the change: it must answer the entry point
    again through the new router on publication (ADR-0013). Raises with every failure seen."""
    ctx.runner.echo("# Back to the entry point")
    try:
        ctx.apply(key, empty_plan=False)
        if after_apply:
            after_apply()
        transit(ctx, report)
        publish(ctx, report, load=load)
        ctx.scene_done(key)
    except Exception as error:  # the HTTPS checks below still run: they tell what is broken
        failures.append(f"restore of {key}: {error}")
    address = entry_address(ctx)
    for domain in domains(ctx, *names):
        try:
            wait_https(ctx, domain, address, report=report)
            https_probe(ctx, report, domain, address)
        except StepFailed as error:
            failures.append(str(error))
    if failures:
        raise StepFailed("; ".join(failures))


def apply_addons(ctx):
    """The ingress settings are in the cluster's add-ons: after a change of the stack, the cluster
    is updated as the stack's README says (update-cluster.sh), then the Service must get the
    address of the stack."""
    k = update_cluster(ctx, STACK, kubeconfig(ctx, STACK))
    address = service_address(ctx, STACK)
    for _ in range(60):
        if ctx.runner.dry_run or ingress_address(ctx) == address:
            k.show("-n", "traefik", "get", "svc", "traefik")
            return
        ctx.sleep(10)
    raise StepFailed(f"the ingress Service did not get {address}")


@step(
    "direct-k8s",
    guide=[
        "docs/reference/test-procedure.md#direct-exposure",
        "stacks/tenants/kubernetes/README.md#change-the-exposure-of-an-existing-cluster",
    ],
)
def direct_k8s(ctx, report):
    """The published cluster exposed directly (exposure = "public"): the ingress moves to a
    public floating IP once the add-ons are applied again, HTTPS there with the certificate
    checked, the entry point no longer reaches the cluster. Then back to the entry point."""
    # The scene answers with the demo application: deploy it when the accept step has not run.
    deploy_demo(ctx)
    before = service_address(ctx, STACK)
    failures = []
    with ctx.scene(STACK) as inputs:
        edit_inputs(ctx, inputs, lambda v: v.update(exposure="public"))
        try:
            ctx.apply(STACK, empty_plan=False)
            apply_addons(ctx)
            address = service_address(ctx, STACK)
            record(ctx, [f"ingress, exposed directly: {address}"])
            https_probe(ctx, report, domains(ctx, "apps.published")[0], address)
        except StepFailed as error:
            failures.append(str(error))
        ctx.runner.echo("# The entry point no longer reaches the cluster")
        bastion, edge = entry_point_instance(ctx)
        if reachable(ctx, bastion, edge, before):
            failures.append(f"the entry point still reaches {before}")
        else:
            record(ctx, [f"entry point -> {before}:443 closed"])
    # Republished with the load: the entry point did not serve the domain during the scene, so
    # the load runs only if requested, as in run.sh (first publication of the domain again).
    back_to_entry_point(ctx, report, STACK, ["apps.published"], failures, after_apply=lambda: apply_addons(ctx), load=None)


@step("hostile", guide="docs/reference/test-procedure.md#hostile-route-interface-mode")
def hostile(ctx, report):
    """Interface mode: a tenant adds a route to another tenant through the transit router. The
    connections stay closed: the security groups decide, not the routes."""
    if ctx.mode != "interface":
        ctx.runner.echo("interface mode only")
        return
    hop = ctx.setting("hostile_next_hop")
    web = ctx.options.get("planes", {}).get("attachments", {}).get("web", {}).get("cidr", "10.21.0.0/24")

    def add_route(values):
        observability = values["plane_attachment"]["observability"]
        observability["routes"] = list(observability.get("routes", [])) + [{"destination": web, "next_hop": hop}]

    with ctx.scene("private") as inputs:
        edit_inputs(ctx, inputs, add_route)
        ctx.apply("private", empty_plan=False)
        bastion = ctx.value("private", "bastion")
        instance = ctx.instances("private")[0]
        target = ctx.instances("vm")[0]
        ctx.wait_for_instances(bastion, [instance])
        # The route is on the tenant's transit router (ADR-0013): it applies at once.
        opened = [port for port in (443, 22, 9100) if reachable(ctx, bastion, instance, target, port)]
        record(
            ctx,
            [f"hostile route {instance} -> {target}:{port} {'OPEN' if port in opened else 'closed'}" for port in (443, 22, 9100)],
        )
    ctx.apply("private", empty_plan=False)
    ctx.scene_done("private")
    report.measures["hostile"] = "closed" if not opened else f"open: {opened}"
    if opened:
        raise StepFailed(f"a hostile route opened {target} on ports {opened}")
