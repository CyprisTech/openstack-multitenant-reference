"""The end of a campaign: nothing drifted, then nothing left."""

import time
from concurrent.futures import ThreadPoolExecutor

from ..checks import kubeconfig
from ..contents import project_contents
from ..context import StepFailed
from ..kube import delete_cluster
from . import step

# The teardown in waves, the stacks of a wave destroyed in parallel: the clusters (deleted by
# Cluster API, then their stack) and the tenants; then the shared services and the fixtures, once
# their consumers are gone; then the planes. Inside a wave nothing depends on anything else. A
# stack of the scenario in no wave goes with the second.
CLUSTERS = ["shared", "published"]
WAVES = [
    ["shared", "published", "vm", "private", "egress-shared"],
    ["internal-service", "resolver", "egress", "entry-point", "receiver", "acme"],
    ["planes"],
]


@step("plans", guide="CONTRIBUTING.md#testing-on-a-real-cloud")
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


@step(
    "teardown",
    guide=[
        "docs/reference/test-procedure.md#10-teardown",
        "docs/guides/teardown.md",
        "docs/guides/kubernetes-lifecycle.md#delete-a-cluster",
    ],
)
def teardown(ctx, report):
    """Removes everything; goes on after a failure to remove as much as possible, then reports."""
    # The next campaign publishes for the first time again: no load during that publication.
    (ctx.work / "published-once").unlink(missing_ok=True)
    listed = {k for wave in WAVES for k in wave}
    waves = [[k for k in wave if ctx.has(k)] for wave in WAVES]
    waves[1] += [k for k in ctx.scenario.stacks if k not in listed]
    keys = [k for wave in waves for k in wave]

    def remove(key, stream):
        """A stack, after its cluster when it has one; the error, or None."""
        if key in CLUSTERS:
            try:
                delete_cluster(ctx, key, kubeconfig(ctx, key))
            except Exception as error:
                return f"cluster {key}: {error}"
        try:
            ctx.destroy(key, stream=stream)
        except Exception as error:
            return f"{key}: {error}"
        return None

    failed, destroyed, timings = [], 0, []
    for number, wave in enumerate(waves, 1):
        if not wave:
            continue
        started = time.monotonic()
        ctx.runner.echo(f"wave {number}: {', '.join(wave)}")
        with ThreadPoolExecutor(max_workers=len(wave)) as pool:
            errors = list(pool.map(remove, wave, [len(wave) == 1] * len(wave)))
        timings.append(f"{number}: {round(time.monotonic() - started)} s")
        destroyed += errors.count(None)
        failed += [e for e in errors if e]
        if failed:  # the next wave depends on this one: stop, the leftovers step reports the rest
            break
    report.measures["destroyed"] = f"{destroyed}/{len(keys)}"
    report.measures["waves"] = ", ".join(timings)
    if failed:
        raise StepFailed("; ".join(failed))


@step("leftovers", guide="docs/reference/test-procedure.md#10-teardown")
def leftovers(ctx, report):
    """Nothing is left in the projects of the scenario after the teardown.

    A listing that fails is a failed check, not zero objects.
    """
    found, failed = project_contents(ctx)
    for line in found:
        ctx.runner.echo("LEFTOVER " + line)
    for line in failed:
        ctx.runner.echo("CHECK FAILED " + line)
    report.measures["leftovers"] = len(found)
    if found or failed:
        raise StepFailed(f"{len(found)} leftovers, {len(failed)} failed listings")
