"""Checks before the first step: every credential the run will use authenticates, and the entries
of different stacks open different projects.

A campaign stopped after an hour on a revoked or misspelled credential costs a rerun; the check
costs a token per credential.
"""

from .contents import project_contents
from .context import StepFailed


def credentials(ctx, names):
    """The clouds.yaml entries the steps `names` use: those of the stacks of the scenario, those of
    its clusters, and the next credential of the shared cluster if the rotation runs."""
    entries = set(ctx.clouds())
    clusters = ctx.config.get("cluster_clouds", {})
    for key in ("published", "shared"):
        if ctx.has(key) and clusters.get(key):
            entries.add(clusters[key])
    if "rotate" in names and clusters.get("shared_next"):
        entries.add(clusters["shared_next"])
    return sorted(entries)


def problems(ctx, names):
    """What would stop the run, as messages; an empty list when it can start."""
    found = []
    clusters = ctx.config.get("cluster_clouds", {})
    if "rotate" in names:
        if not clusters.get("shared_next"):
            found.append("cluster_clouds.shared_next is not set: the rotation needs the next credential")
        elif clusters.get("shared_next") == clusters.get("shared"):
            found.append("cluster_clouds.shared_next is the current credential: create the next one")
    projects = {}
    for entry in credentials(ctx, names):
        result = ctx.runner.run(ctx.openstack._cmd(entry, "token", "issue", "-f", "value", "-c", "project_id"),
                                check=False, quiet=True)  # fmt: skip
        if result.returncode != 0:
            reason = (result.stderr.strip().splitlines() or ["no answer"])[-1]
            found.append(f"{entry} does not authenticate: {reason[:160]}")
        elif result.stdout.strip():
            projects.setdefault(result.stdout.strip(), []).append(entry)
    # Each entry of a stack's project names its own project: two entries in one project mean a
    # credential created in the wrong project (the stacks that share a project share an entry).
    stacks = set(ctx.clouds())
    for project, entries in sorted(projects.items()):
        shared = sorted(e for e in entries if e in stacks)
        if len(shared) > 1:
            found.append(f"{', '.join(shared)} open the same project {project}: one of them was created in the wrong project")
    return found


def foreign_contents(ctx):
    """What the projects hold when no state of the scenario holds anything: objects the campaign
    did not create. A campaign creates then destroys everything: started on the wrong project (a
    clouds.yaml entry pointing elsewhere), it would destroy what it found there. A run started
    again finds its own states and is not stopped."""
    own = [k for k in ctx.scenario.stacks if ctx.tofu.deployed(ctx.stack(k))]
    if own or ctx.runner.dry_run:
        return []
    found, failed = project_contents(ctx)
    return [f"{line}, not created by this campaign" for line in found] + failed


def check(ctx, names, allow_existing=False):
    """Raises with every problem found; prints the credentials checked otherwise."""
    found = problems(ctx, names)
    if not found and not allow_existing:
        found = [f"the projects are not empty: {line}" for line in foreign_contents(ctx)]
        if found:
            found.append("give the campaign empty test projects (or --allow-existing if they hold its own objects)")
    if found:
        raise StepFailed("preflight: " + "; ".join(found))
    ctx.runner.echo(f"preflight: {len(credentials(ctx, names))} credentials authenticate")
