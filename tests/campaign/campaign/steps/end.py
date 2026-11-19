"""The end of a campaign: nothing drifted, then nothing left."""

from ..context import StepFailed
from . import step

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
