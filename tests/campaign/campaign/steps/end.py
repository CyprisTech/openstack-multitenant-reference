"""The end of a campaign: nothing drifted, then nothing left."""

from ..checks import kubeconfig
from ..context import StepFailed
from ..kube import delete_cluster
from . import step

# The clusters first (Cluster API deletes their servers and load balancers), then the stacks,
# consumers before what they consume.
CLUSTERS = ["shared", "published"]
DESTROY_ORDER = [
    "shared", "internal-service", "published", "private", "resolver", "vm", "entry-point", "receiver", "acme", "planes",
]

# Listings of the leftover check: a kind of object and the column holding its ID. The Octavia
# plugin names its columns in lower case. Images are kept (the Kubernetes node image).
LISTINGS = [
    (("server", "list"), "ID"),
    (("loadbalancer", "list"), "id"),
    (("floating", "ip", "list"), "ID"),
    (("router", "list"), "ID"),
    (("volume", "list"), "ID"),
    (("server", "group", "list"), "ID"),
]
PROJECT_LISTINGS = [(("network", "list"), "ID"), (("port", "list"), "ID")]


@step("plans")
def plans(ctx, report):
    """Every stack of the scenario plans no change, but those removed before the end."""
    skip = set(ctx.scenario.options.get("plans", {}).get("skip", []))
    keys = [k for k in ctx.scenario.stacks if k not in skip]
    drifted = []
    for key in keys:
        code = ctx.tofu.plan_exitcode(ctx.stack(key))
        ctx.runner.echo(f"{key}: plan exit={code} (0 = no change)")
        if code != 0:
            drifted.append(key)
    report.measures["plans"] = f"{len(keys) - len(drifted)}/{len(keys)} empty"
    if drifted:
        raise StepFailed(f"plan not empty: {', '.join(drifted)}")


@step("teardown")
def teardown(ctx, report):
    """Removes everything; goes on after a failure to remove as much as possible, then reports."""
    # The next campaign publishes for the first time again: no load during that publication.
    (ctx.work / "published-once").unlink(missing_ok=True)
    failed = []
    for key in CLUSTERS:
        if ctx.has(key):
            try:
                delete_cluster(ctx, key, kubeconfig(ctx, key))
            except Exception as error:
                failed.append(f"cluster {key}: {error}")
    keys = [k for k in DESTROY_ORDER if ctx.has(k)] + [k for k in ctx.scenario.stacks if k not in DESTROY_ORDER]
    for key in keys:
        try:
            ctx.destroy(key)
        except Exception as error:
            failed.append(f"{key}: {error}")
    report.measures["destroyed"] = f"{len(keys) - len([f for f in failed if not f.startswith('cluster')])}/{len(keys)}"
    if failed:
        raise StepFailed("; ".join(failed))


@step("leftovers")
def leftovers(ctx, report):
    """Nothing is left in the projects of the scenario after the teardown.

    A listing that fails is a failed check, not zero objects.
    """
    found, failed = [], []
    for cloud in ctx.clouds():
        try:
            project = ctx.openstack.project_id(cloud)
        except Exception as error:
            failed.append(f"{cloud}: token ({error})")
            continue
        listings = LISTINGS + [(listing + ("--project", project), column) for listing, column in PROJECT_LISTINGS]
        for listing, column in listings:
            what = " ".join(listing[:2])
            try:
                ids = ctx.openstack.ids(cloud, *listing, column=column)
            except Exception:
                failed.append(f"{cloud}: {what} (the listing itself failed)")
                continue
            if ids:
                found.append(f"{cloud}: {len(ids)} from {what}")
        try:
            groups = ctx.openstack.ids(cloud, "security", "group", "list", "--project", project, column="Name")
        except Exception:
            failed.append(f"{cloud}: security group list (the listing itself failed)")
        else:
            others = [g for g in groups if g != "default"]
            if others:
                found.append(f"{cloud}: {len(others)} security groups")
    for line in found:
        ctx.runner.echo("LEFTOVER " + line)
    for line in failed:
        ctx.runner.echo("CHECK FAILED " + line)
    report.measures["leftovers"] = len(found)
    if found or failed:
        raise StepFailed(f"{len(found)} leftovers, {len(failed)} failed listings")
