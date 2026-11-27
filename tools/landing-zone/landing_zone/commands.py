"""The commands of lz that read a deployment without changing it (plan, status), and the one that
updates its Kubernetes clusters as a whole (update-clusters)."""

import json
import os
from urllib.parse import urlsplit

from . import isolation
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
            if config.exists():
                line += ", " + revision_state(ctx, key, config)
        lines.append(line)
    return lines


def revision_state(ctx, key, config):
    """Whether a cluster runs the revision of its stack (update-cluster.sh writes it in the
    ConfigMap platform/landing-zone once it applied the stack's manifests)."""
    try:
        expected = ctx.value(key, "revision")
    except Exception:
        return "revision unknown (no revision output)"
    found = ctx.runner.run(["kubectl", "--kubeconfig", str(config), "--request-timeout=15s", "-n", "platform", "get",
                            "configmap", "landing-zone", "-o", "jsonpath={.data.revision}"], check=False, quiet=True)  # fmt: skip
    running = found.stdout.strip() if found.returncode == 0 else ""
    if ctx.runner.dry_run or running == expected:
        return "runs its stack's revision"
    return f"behind its stack (runs {running[:12] or 'no recorded revision'}): lz update-clusters"


def update_clusters(ctx):
    """Each deployed cluster of the scenario updated from its stack (update-cluster.sh), as after
    an apply of its stack. Returns the clusters updated."""
    updated = []
    for key in ctx.options.get("clusters", KUBERNETES):
        if ctx.has(key) and ctx.tofu.deployed(ctx.stack(key)) and (ctx.runner.dry_run or kubeconfig(ctx, key).exists()):
            update_cluster(ctx, key, kubeconfig(ctx, key))
            updated.append(key)
    return updated


def members(ctx, config):
    """The members of a deployment with the facts their stacks give, for the isolation rows."""

    def output(key, name, default=None):
        try:
            value = ctx.value(key, name)
        except Exception:  # an output the stack does not have, or a stack not deployed
            return default
        if value is None:
            return default
        if ctx.runner.dry_run and isinstance(default, dict) and not isinstance(value, dict):
            # A placeholder in a dry run: shaped as the output, so that the rows can be listed.
            return {f"{key}-1": value} if name == "instances" else {}
        return value

    found = []
    if ctx.has("entry-point"):
        lb = output("entry-point", "load_balancer", {})
        found.append(isolation.Member(
            name="entry-point", role="entry-point", planes={"publication": "shared", "observability": "tenant"},
            instances=output("entry-point", "instances", {}), bastion=output("entry-point", "bastion"),
            public_address=lb.get("floating_ip") if isinstance(lb, dict) else None))  # fmt: skip
    for kind, role in (("tenants", "tenant"), ("shared-services", "service")):
        for m in config.get(kind, []):
            name = m["name"]
            if m["type"] == "existing":  # a target only, at the addresses it declares; a source if it says how
                probe = m.get("probe", {})
                instances = dict(m.get("probe_addresses", {}))
                if probe.get("host"):
                    instances.setdefault(name, probe["host"])
                found.append(isolation.Member(name=name, role=role, planes=m["planes"], instances=instances,
                                              bastion=probe.get("jump"), consumers=m.get("consumers", [])))  # fmt: skip
                continue
            if not ctx.has(name):
                continue
            service = output(name, "service_address")
            found.append(isolation.Member(
                name=name, role=role, planes=m["planes"], instances=output(name, "instances", {}),
                bastion=output(name, "bastion"), service_address=service.split(":")[0] if service else None,
                services=output(name, "services", {}) if role == "service" else {},
                consumers=m.get("consumers", []), egress=m.get("values", {}).get("egress")))  # fmt: skip
    return found


def receiver_endpoint(ctx):
    """host:port of the metrics receiver, from its URL, or None."""
    try:
        url = urlsplit(ctx.value("receiver", "receiver_url"))
    except Exception:
        return None
    if not url.hostname:
        return None
    return f"{url.hostname}:{url.port or (443 if url.scheme == 'https' else 80)}"


def own_rows(config, found):
    """The adopter's own rows: the file named by [check] rows, each with from (a member, or "local"
    for the machine running lz), to (an address), port and expected ("open" or "closed")."""
    import tomllib  # noqa: PLC0415
    from pathlib import Path  # noqa: PLC0415

    name = config.get("check", {}).get("rows")
    if not name:
        return []
    with open(Path(config["base"]) / name, "rb") as f:
        listed = tomllib.load(f).get("rows", [])
    sources = {m.name: m.source() for m in found}
    out = []
    for r in listed:
        source = isolation.LOCAL if r["from"] == "local" else sources.get(r["from"])
        if source is None:
            raise ValueError(f"[check] rows: {r['from']} is not a member with instances and a bastion")
        out.append(isolation.row(source, isolation.target(r["to"], r.get("label", r["to"])), int(r["port"]),
                                 r["expected"], "own"))  # fmt: skip
    return out


def check(ctx, config):
    """The isolation of the deployment: the rows of its members (isolation.rows), written to
    <work>/isolation-rows.json, then probed by tests/isolation/check.py. Returns the exit code."""
    found = members(ctx, config)
    rows = isolation.rows(found, receiver=receiver_endpoint(ctx))
    rows += own_rows(config, found)
    ctx.work.mkdir(parents=True, exist_ok=True)
    path = ctx.work / "isolation-rows.json"
    path.write_text(json.dumps(rows, indent=2) + "\n")
    print(f"{len(rows)} rows from the configuration: {path}")
    if ctx.runner.dry_run:
        for r in rows:
            print(f"  {r['source']['label']:<28} {r['target']['label']:<52} {r['port']:>5}  {r['expected']}  ({r['rule']})")
        return 0
    cmd = ["python3", "tests/isolation/check.py", "--rows", str(path), "--user", ctx.setting("ssh_user"),
           "--key", os.path.expanduser(ctx.setting("ssh_key"))]  # fmt: skip
    return ctx.runner.run(cmd, cwd=ctx.root, check=False).returncode
