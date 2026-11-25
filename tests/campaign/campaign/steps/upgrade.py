"""The upgrade from the previous release: the new release applied over its states (spec
docs/specs/upgrades.md, part 5). run.py --from deploys the previous release first."""

from ..context import StepFailed
from ..previous import Migration
from . import STEPS, step
from .foundation import Load
from .shared import ConsumerLoad, consumer_instance, service_address


def loads(ctx):
    """Requests during the applies: a published domain through the entry point, and the shared
    cluster's internal service from a tenant instance, when they are deployed."""
    found = []
    if ctx.has("entry-point") and ctx.tofu.deployed(ctx.stack("entry-point")):
        found.append(Load(ctx))
    if ctx.has("shared") and ctx.has("vm") and ctx.tofu.deployed(ctx.stack("shared")):
        bastion, instance = consumer_instance(ctx)
        found.append(ConsumerLoad(ctx, bastion, instance, service_address(ctx)))
    return found


def into_workspace(ctx, key):
    """A stack the previous release kept in the default workspace of a directory this release
    shares between tenants: its state moves to the stack's workspace, once. A layout of the
    campaign, not of a deployment: a user with one tenant per directory has nothing to move."""
    stack = ctx.stack(key)
    state = ctx.root / stack / "terraform.tfstate"
    if not stack.workspace or not state.exists() or (ctx.root / stack / "terraform.tfstate.d" / stack.workspace).exists():
        return
    ctx.runner.run(ctx.tofu._cmd(stack, "init", "-input=false", "-no-color"), cwd=ctx.root, quiet=True)
    # workspace new -state= creates the workspace without copying the state (seen with OpenTofu 1.13): push it.
    ctx.runner.run(ctx.tofu._cmd(stack, "workspace", "new", stack.workspace), cwd=ctx.root, quiet=True)
    ctx.runner.run(ctx.tofu._cmd(stack, "state", "push", str(state)), cwd=ctx.root, env=stack.env(), quiet=True)
    if not ctx.runner.dry_run:
        state.rename(state.with_name("terraform.tfstate.previous"))
    ctx.runner.echo(f"{key}: state of the default workspace moved to workspace {stack.workspace}")


@step("migrate")
def migrate(ctx, report):
    """The steps of options.from.apply, in order, under load: each deployed stack is planned
    (kept, with what it replaces and destroys) then applied; the stacks the release adds are
    created. migration.json lists, per stack, the replaced and destroyed resources and the
    requests that failed during its apply: the draft of the migration notes."""
    names = ctx.options.get("from", {}).get("apply", [])
    if not names:
        raise StepFailed("the scenario has no options.from.apply")
    unknown = [n for n in names if n not in STEPS or n == "migrate"]
    if unknown:
        raise StepFailed(f"options.from.apply: unknown steps {unknown}")
    for key in ctx.options.get("from", {}).get("default_state", []):
        into_workspace(ctx, key)
    running = [] if ctx.runner.dry_run else loads(ctx)
    for load in running:
        load.start()
    ctx.migration = Migration(ctx, running)
    try:
        for name in names:
            ctx.runner.echo(f"-- migrate: {name}")
            STEPS[name](ctx, report)
    finally:
        for load in running:
            load.stop()
        ctx.migration.write()
        lines = ctx.migration.summary()
        ctx.migration = None
    report.measures["requests"] = "; ".join(f"{load.label}: {load.summary()}" for load in running) or "none"
    report.measures["migration"] = "; ".join(lines) or "nothing replaced or destroyed"
    for line in lines:
        ctx.runner.echo(f"migration: {line}")
