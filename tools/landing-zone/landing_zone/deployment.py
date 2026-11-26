"""lz deploy: the adopter's landing zone, from its configuration file (ADR-0018, D3).

The configuration names the shared stacks, the tenants and the adopter's own services; this
module checks it, then builds the scenario that lz runs: the stacks with their states and inputs
files, the attachments of the planes, and the steps of each tenant.
"""

import ipaddress
import re
import tomllib
from functools import partial
from pathlib import Path

from .checks import kubeconfig
from .kube import create_cluster, update_cluster, wait_for_bootstrap
from .scenario import Scenario
from .steps import STEPS
from .steps.foundation import attachment, cluster_credential, edge_sources, monitoring

NAME = re.compile(r"^[a-z][a-z0-9-]{0,29}$")
TENANT_STACKS = {"vm": "stacks/tenants/vm", "kubernetes": "stacks/tenants/kubernetes"}
SHARED_STACKS = {"planes": "stacks/shared/planes", "egress": "stacks/shared/egress", "entry-point": "stacks/shared/entry-point"}
# The attachments of the shared stacks: their name in the planes stack, and their roles.
SHARED_ATTACHMENTS = {
    "entry-point": ("edge", {"publication": "shared", "observability": "tenant"}),
    "egress": ("egress", {"internal": "shared", "observability": "tenant"}),
}
# The adopter's own inputs of a shared stack, beside its other inputs: read by tofu by itself, so
# that the scripts of the guides plan the stack as lz does; before mode.auto.tfvars.json, which wins.
OWN_INPUTS = "lz-inputs.auto.tfvars"
RESERVED = {*SHARED_STACKS, "edge", "shared", "receiver", "acme", "resolver", "internal-service"}
PLANES = {"publication", "observability", "internal"}
ROLES = {"tenant", "shared"}
PROFILES = {"private-cloud", "public-cloud"}
MODES = {"gateway", "interface"}


class ConfigError(Exception):
    """A configuration that cannot be deployed: every problem found, each saying what to fix."""

    def __init__(self, path, problems):
        self.problems = problems
        super().__init__(f"{path}:\n" + "\n".join(f"  - {p}" for p in problems))


def load(path):
    """The configuration, checked: raises ConfigError with every problem found."""
    path = Path(path).resolve()
    try:
        with path.open("rb") as f:
            config = tomllib.load(f)
    except (OSError, tomllib.TOMLDecodeError) as error:
        raise ConfigError(path, [str(error)]) from error
    problems = check(config, path.parent)
    if problems:
        raise ConfigError(path, problems)
    config["base"] = str(path.parent)
    return config


def check(config, base):
    """The problems of a configuration, as sentences that say what to fix."""
    problems = []
    if config.get("profile") not in PROFILES:
        problems.append(f"profile: one of {', '.join(sorted(PROFILES))}")
    if config.get("mode") not in MODES:
        problems.append(f"mode: the plane mode, one of {', '.join(sorted(MODES))}")
    if not NAME.match(str(config.get("site", ""))):
        problems.append("site: a short name (lowercase letters, digits, dashes), the prefix of every resource")
    clouds = config.get("clouds", {})
    for key in ("planes", "entry-point"):
        if not clouds.get(key):
            problems.append(f"clouds.{key}: the clouds.yaml entry of the {key} stack's project")
    receiver = config.get("external", {}).get("monitoring", {}).get("receiver", "")
    if not str(receiver).startswith(("http://", "https://")):
        problems.append("external.monitoring.receiver: the remote write URL of your metrics receiver")
    for key, stack in config.get("stacks", {}).items():
        if key not in SHARED_STACKS:
            problems.append(f"stacks.{key}: not a shared stack ({', '.join(sorted(SHARED_STACKS))})")
        elif stack.get("inputs") and not (base / stack["inputs"]).exists():
            problems.append(f"stacks.{key}.inputs: no file {stack['inputs']}")
    if not config.get("stacks", {}).get("planes", {}).get("inputs"):
        problems.append("stacks.planes.inputs: the planes of the landing zone (from examples/planes)")
    for key in SHARED_ATTACHMENTS:
        if key in clouds or key == "entry-point":
            try:
                ipaddress.ip_network(config.get("stacks", {}).get(key, {}).get("cidr", ""))
            except ValueError:
                problems.append(f"stacks.{key}.cidr: the range of the {key} stack's network, e.g. 10.20.0.0/24")
    admin = config.get("admin", {})
    if not admin.get("ssh_user") or not admin.get("ssh_key"):
        problems.append("admin.ssh_user, admin.ssh_key: the user and the key lz connects with to the bootstrap instances")
    state = config.get("state")
    if state is not None:
        if not state.get("backend"):
            problems.append("state.backend: the Terraform backend of the states (s3, http, pg, local…)")
        if "{stack}" not in state.get("key", ""):
            problems.append('state.key: the backend setting of each state, with {stack}, e.g. "key=par1/{stack}.tfstate"')
    tenants = config.get("tenants", [])
    if not tenants:
        problems.append("tenants: at least one [[tenants]] block")
    seen = set()
    for index, tenant in enumerate(tenants):
        where = f"tenants[{index}]" + (f" ({tenant['name']})" if tenant.get("name") else "")
        name = tenant.get("name", "")
        if not NAME.match(name) or name in RESERVED:
            problems.append(f"{where}.name: a short name (lowercase letters, digits, dashes), not {', '.join(sorted(RESERVED))}")
        elif name in seen:
            problems.append(f"{where}.name: {name} is used twice")
        seen.add(name)
        if tenant.get("type") not in TENANT_STACKS:
            problems.append(f"{where}.type: one of {', '.join(TENANT_STACKS)}")
        if not tenant.get("cloud"):
            problems.append(f"{where}.cloud: the clouds.yaml entry of the tenant's project")
        try:
            ipaddress.ip_network(tenant.get("cidr", ""))
        except ValueError:
            problems.append(f"{where}.cidr: the range of the tenant's network, e.g. 10.21.0.0/24")
        planes = tenant.get("planes", {})
        if not planes or any(p not in PLANES or r not in ROLES for p, r in planes.items()):
            problems.append(f"{where}.planes: each plane ({', '.join(sorted(PLANES))}) with its role (tenant or shared)")
        if not tenant.get("inputs") or not (base / tenant["inputs"]).exists():
            problems.append(f"{where}.inputs: the tenant's own inputs file (exposure, egress, domains, sizes), which must exist")
        if tenant.get("type") == "kubernetes" and not tenant.get("cluster_cloud"):
            problems.append(f"{where}.cluster_cloud: the clouds.yaml entry of the cluster's application credential")
    return problems


def backend(config, key):
    """The backend of a stack's state, or None for a local state beside the stack."""
    state = config.get("state")
    if not state:
        return None
    return {"type": state["backend"], "config": state.get("config", {}), "key": state["key"].format(stack=key)}


def scenario(config):
    """The scenario of the deployment: its stacks, their states and inputs, the attachments."""
    base = Path(config["base"])
    stacks, states, options = {}, {}, {"stacks": {}, "planes": {"attachments": {}}}
    attachments = options["planes"]["attachments"]
    for key, path in SHARED_STACKS.items():
        if key == "egress" and not config.get("clouds", {}).get("egress"):
            continue
        stacks[key] = path  # one per directory: its own inputs file sits beside it (OWN_INPUTS)
        options["stacks"][key] = {"backend": backend(config, key)}
        if key in SHARED_ATTACHMENTS:
            name, roles = SHARED_ATTACHMENTS[key]
            attachments[name] = {"stack": key, "cidr": config["stacks"][key]["cidr"], "planes": roles}
    for tenant in config["tenants"]:
        name = tenant["name"]
        stacks[name], states[name] = TENANT_STACKS[tenant["type"]], name
        options["stacks"][name] = {"inputs": [str(base / tenant["inputs"])], "backend": backend(config, name)}
        attachments[name] = {"stack": name, "cidr": tenant["cidr"], "planes": tenant["planes"]}
    # The ranges each plane routes to: those of the attachments that take it as tenants.
    ranges = {}
    for spec in attachments.values():
        for plane, role in spec["planes"].items():
            if role == "tenant":
                ranges.setdefault(plane, []).append(spec["cidr"])
    options["planes"]["tenant_ranges"] = ranges
    options["clusters"] = [t["name"] for t in config["tenants"] if t["type"] == "kubernetes"]
    options["planes"]["own_inputs"] = True  # the planes themselves are in the stack's own inputs file
    sequence = ["prep", "planes"]
    sequence += ["deploy-egress"] if "egress" in stacks else []
    sequence += ["deploy-entry-point"]
    sequence += [f"tenant-{t['name']}" for t in config["tenants"]]
    sequence += ["deploy-egress-tenants"] if "egress" in stacks else []
    sequence += ["transit", "deploy-publish"]
    sequence += [f"cluster-{t['name']}" for t in config["tenants"] if t["type"] == "kubernetes"]
    return Scenario(
        name="deploy", profile=config["profile"], modes=[config["mode"]], stacks=stacks, states=states,
        sequences={"deploy": sequence}, options=options,
    )  # fmt: skip


def prepare(ctx, config):
    """The context of a deployment: the adopter's services as values, the settings lz reads, and
    the steps of each tenant."""
    external = config.get("external", {})
    ctx.external = {"receiver": {"receiver_url": external["monitoring"]["receiver"]}}
    if external.get("resolvers"):
        ctx.external["resolver"] = {"resolver": external["resolvers"][0]}
    ctx.config.setdefault("clouds", {}).update(config.get("clouds", {}))
    ctx.config["clouds"].update({t["name"]: t["cloud"] for t in config["tenants"]})
    ctx.config.setdefault("site", config["site"])
    ctx.config.setdefault("ssh_user", config["admin"]["ssh_user"])
    ctx.config.setdefault("ssh_key", config["admin"]["ssh_key"])
    base = Path(config["base"])
    for key, stack in config.get("stacks", {}).items():
        if stack.get("inputs") and key in ctx.scenario.stacks and not ctx.runner.dry_run:
            link = ctx.root / ctx.scenario.stacks[key] / OWN_INPUTS
            link.unlink(missing_ok=True)
            link.symlink_to(base / stack["inputs"])
    for tenant in config["tenants"]:
        STEPS[f"tenant-{tenant['name']}"] = partial(tenant_step, tenant=tenant)
        if tenant["type"] == "kubernetes":
            STEPS[f"cluster-{tenant['name']}"] = partial(cluster_step, tenant=tenant)
    STEPS["deploy-egress"] = deploy_egress
    STEPS["deploy-entry-point"] = deploy_entry_point
    STEPS["deploy-egress-tenants"] = partial(deploy_egress_tenants, tenants=config["tenants"])
    STEPS["deploy-publish"] = partial(deploy_publish, tenants=config["tenants"])


# --- steps of a deployment -------------------------------------------------------------------------


def deploy_egress(ctx, report):
    """The shared egress with no tenant yet: they are declared once their address is known."""
    ctx.set_inputs("egress", cloud=ctx.cloud("egress"), plane_attachment=attachment(ctx, "egress"),
                   monitoring=monitoring(ctx), tenants={})  # fmt: skip
    ctx.apply("egress")


def deploy_entry_point(ctx, report):
    ctx.set_inputs("entry-point", cloud=ctx.cloud("entry-point"), plane_attachment=attachment(ctx, "edge"),
                   monitoring=monitoring(ctx))  # fmt: skip
    ctx.apply("entry-point")


def tenant_step(ctx, report, tenant):
    """A tenant: what the landing zone gives it (its attachment, the receiver, the sources of the
    entry point, a resolver), then its own inputs file; a Kubernetes tenant with its bootstrap
    instance."""
    name = tenant["name"]
    inputs = dict(cloud=ctx.cloud(name), plane_attachment=attachment(ctx, name), monitoring=monitoring(ctx))
    if tenant["type"] == "vm":
        inputs["name"] = name  # the vm stack's resources are named after it
    if "publication" in tenant["planes"]:
        inputs["edge_sources"] = edge_sources(ctx)
    if tenant["type"] == "vm" and "resolver" in ctx.external and "internal" in tenant["planes"]:
        inputs["dns_nameservers"] = [ctx.value("resolver", "resolver")]
    if tenant.get("egress_proxy") and ctx.has("egress"):
        inputs["shared_egress"] = {"proxy": ctx.value("egress", "proxy")}
    if tenant["type"] == "kubernetes":
        inputs["bootstrap"] = not kubeconfig(ctx, name).exists()
    ctx.set_inputs(name, **inputs)
    ctx.apply(name)
    if tenant["type"] == "kubernetes" and inputs["bootstrap"]:
        wait_for_bootstrap(ctx, name)


def deploy_egress_tenants(ctx, report, tenants):
    """The tenants that go out through the shared egress, declared with their address on the
    internal services plane and the names they may reach."""
    declared = {
        t["name"]: {"sources": ctx.value(t["name"], "internal_sources"), "domains": t.get("egress_domains", [])}
        for t in tenants
        if t.get("egress_proxy")
    }
    ctx.set_inputs("egress", cloud=ctx.cloud("egress"), plane_attachment=attachment(ctx, "egress"),
                   monitoring=monitoring(ctx), tenants=declared)  # fmt: skip
    ctx.apply("egress")


def deploy_publish(ctx, report, tenants):
    """The domains of the tenants on the entry point: each tenant's request into the reviewed
    domains file, then the publication (ADR-0016, D5)."""
    import os  # noqa: PLC0415

    for tenant in tenants:
        if "publication" not in tenant["planes"]:
            continue
        stack = ctx.stack(tenant["name"])
        result = ctx.runner.run(["scripts/request-domains.sh", stack, "--tool", ctx.tool], cwd=ctx.root, env=stack.env(),
                                check=False)  # fmt: skip
        if result.returncode != 0:
            raise RuntimeError(f"request-domains.sh failed for {tenant['name']}:\n{result.stderr.strip()}")
    env = dict(os.environ, OS_CLOUD=ctx.cloud("entry-point"))
    result = ctx.runner.run(["scripts/publish-domains.sh", "--tool", ctx.tool], cwd=ctx.root, env=env, check=False)
    if result.returncode != 0:
        raise RuntimeError(f"publish-domains.sh failed:\n{result.stderr.strip()}")


def cluster_step(ctx, report, tenant):
    """A Kubernetes tenant's cluster: created from its bootstrap instance the first time, then
    updated from the stack (update-cluster.sh) at each deployment."""
    name = tenant["name"]
    config = kubeconfig(ctx, name)
    if config.exists():
        update_cluster(ctx, name, config)
        return
    credential = ctx.work / f"{name}-clouds.yaml"
    cluster_credential(ctx, tenant["cluster_cloud"], credential)
    create_cluster(ctx, name, credential, config)
