"""The commands of lz that read a deployment without changing it (plan, status), and the one that
updates its Kubernetes clusters as a whole (update-clusters)."""

import json

from .checks import kubeconfig
from .kube import update_cluster
from .previous import changes

# The Kubernetes stacks of a scenario: their clusters take the stack's manifests through their API.
KUBERNETES = ("shared", "published")


def plan(ctx):
    """Each deployed stack of the scenario planned: what an apply would create, update, replace and
    destroy. The plans are kept in <work>/plans. Returns the lines to print and whether any stack
    would change or failed to plan."""
    plans = ctx.work / "plans"
    plans.mkdir(parents=True, exist_ok=True)
    lines, changed = [], False
    for key in ctx.scenario.stacks:
        stack = ctx.stack(key)
        ctx.tofu.init(stack)
        if not ctx.tofu.deployed(stack):
            lines.append(f"{key:<18} not deployed")
            continue
        out = plans / f"{key}.tfplan"
        cmd = ctx.tofu._cmd(stack, "plan", "-input=false", "-no-color", f"-out={out}", *stack.var_files())
        result = ctx.runner.run(cmd, cwd=ctx.root, env=stack.env(), check=False, quiet=True)
        if ctx.runner.dry_run:
            continue
        (plans / f"{key}.txt").write_text(result.stdout + result.stderr)
        if result.returncode != 0:
            lines.append(f"{key:<18} plan failed (plans/{key}.txt)")
            changed = True
            continue
        show = ctx.runner.run(ctx.tofu._cmd(stack, "show", "-json", str(out)), cwd=ctx.root, env=stack.env(), quiet=True)
        found = changes(json.loads(show.stdout))
        counts = {k: len(v) for k, v in found.items() if v}
        if not counts:
            lines.append(f"{key:<18} no change")
            continue
        changed = True
        lines.append(f"{key:<18} " + ", ".join(f"{n} {k}" for k, n in counts.items()))
        for kind in ("replaced", "destroyed"):
            lines += [f"{'':<18}   {kind}: {address}" for address in found[kind]]
    return lines, changed


def status(ctx):
    """What is deployed: each stack of the scenario and the number of resources in its state, and
    the kubeconfig of each cluster. Nothing is planned: lz plan says what would change."""
    lines = []
    for key in ctx.scenario.stacks:
        stack = ctx.stack(key)
        ctx.tofu.init(stack)
        listed = ctx.runner.run(ctx.tofu._cmd(stack, "state", "list"), cwd=ctx.root, env=stack.env(), check=False,
                                quiet=True)  # fmt: skip
        count = len(listed.stdout.split()) if listed.returncode == 0 else 0
        line = f"{key:<18} " + (f"{count} resources" if count else "not deployed")
        if key in ctx.options.get("clusters", KUBERNETES) and count:
            config = kubeconfig(ctx, key)
            created = f", kubeconfig {config}"
            line += created if config.exists() else ", no kubeconfig yet (its bootstrap instance creates the cluster)"
        lines.append(line)
    return lines


def update_clusters(ctx):
    """Each deployed cluster of the scenario updated from its stack (update-cluster.sh), as after
    an apply of its stack. Returns the clusters updated."""
    updated = []
    for key in ctx.options.get("clusters", KUBERNETES):
        if ctx.has(key) and ctx.tofu.deployed(ctx.stack(key)) and (ctx.runner.dry_run or kubeconfig(ctx, key).exists()):
            update_cluster(ctx, key, kubeconfig(ctx, key))
            updated.append(key)
    return updated
