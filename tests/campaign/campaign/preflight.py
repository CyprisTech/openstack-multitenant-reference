"""Checks before the first step: every credential the run will use authenticates.

A campaign stopped after an hour on a revoked or misspelled credential costs a rerun; the check
costs a token per credential.
"""

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
    for entry in credentials(ctx, names):
        result = ctx.runner.run(ctx.openstack._cmd(entry, "token", "issue", "-f", "value", "-c", "expires"),
                                check=False, quiet=True)  # fmt: skip
        if result.returncode != 0:
            reason = (result.stderr.strip().splitlines() or ["no answer"])[-1]
            found.append(f"{entry} does not authenticate: {reason[:160]}")
    return found


def check(ctx, names):
    """Raises with every problem found; prints the credentials checked otherwise."""
    found = problems(ctx, names)
    if found:
        raise StepFailed("preflight: " + "; ".join(found))
    ctx.runner.echo(f"preflight: {len(credentials(ctx, names))} credentials authenticate")
