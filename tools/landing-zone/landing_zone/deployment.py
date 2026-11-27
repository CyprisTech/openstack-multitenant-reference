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
from .scenario import SERVICE_STACKS, TENANT_STACKS, Scenario
from .steps import GUIDES, STEPS
from .steps.foundation import attachment, cluster_credential, edge_sources, monitoring

NAME = re.compile(r"^[a-z][a-z0-9-]{0,29}$")
# What lz deploys in the project of a tenant or a shared service, by type: a stack, or nothing
# but the attachment of an existing project to the planes.
SHARED_STACKS = {"planes": "stacks/shared/planes", "egress": "stacks/shared/egress", "entry-point": "stacks/shared/entry-point"}
# The attachments of the shared stacks: their name in the planes stack, and their roles.
SHARED_ATTACHMENTS = {
    "entry-point": ("edge", {"publication": "shared", "observability": "tenant"}),
    "egress": ("egress", {"internal": "shared", "observability": "tenant"}),
}
RESERVED = {*SHARED_STACKS, "edge", "receiver", "acme", "resolver", "internal-service"}
PLANES = {"publication", "observability", "internal"}
ROLES = {"tenant", "shared"}
PROFILES = {"private-cloud", "public-cloud"}
MODES = {"gateway", "interface"}
# The values a shared service of the adopter, or the [external] table, may give the tenants: the
# remote write URL of a metrics receiver, a resolver, the ACME settings of each tenant.
PROVIDED = {"receiver", "resolver", "certificates"}
# The adopter's own inputs of a shared stack, beside its other inputs: read by tofu by itself, so
# that the scripts of the guides plan the stack as lz does; before mode.auto.tfvars.json, which wins.
OWN_INPUTS = "lz-inputs.auto.tfvars"


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
    config.setdefault("shared-services", [])
    return config


def provided(config):
    """The values given to the tenants: the [external] table, then those of the shared services."""
    values = {k: v for k, v in config.get("external", {}).items() if k in PROVIDED}
    for service in config.get("shared-services", []):
        values.update(service.get("provides", {}))
    return values


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
    unknown = set(config.get("external", {})) - PROVIDED
    if unknown:
        problems.append(f"external: unknown {', '.join(sorted(unknown))} (one of {', '.join(sorted(PROVIDED))})")
    if not str(provided(config).get("receiver", "")).startswith(("http://", "https://")):
        problems.append("external.receiver: the remote write URL of your metrics receiver (or a shared service that provides it)")
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
        problems.append("admin.ssh_user, admin.ssh_key: the user and the key lz connects with to the instances")
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
    names = {t.get("name") for t in tenants}
    for kind, members, types in (("tenants", tenants, TENANT_STACKS), ("shared-services", config.get("shared-services", []),
                                                                       SERVICE_STACKS)):  # fmt: skip
        for index, member in enumerate(members):
            problems += check_member(kind, index, member, types, base, seen, names)
    return problems


def check_member(kind, index, member, types, base, seen, tenants):
    """The problems of a tenant or a shared service."""
    problems = []
    name = member.get("name", "")
    where = f"{kind}[{index}]" + (f" ({name})" if name else "")
    if not NAME.match(name) or name in RESERVED:
        problems.append(f"{where}.name: a short name (lowercase letters, digits, dashes), not {', '.join(sorted(RESERVED))}")
    elif name in seen:
        problems.append(f"{where}.name: {name} is used twice")
    seen.add(name)
    kind_type = member.get("type")
    if kind_type not in types:
        problems.append(f"{where}.type: one of {', '.join(types)}")
    if not member.get("cloud"):
        problems.append(f"{where}.cloud: the clouds.yaml entry of its project")
    try:
        ipaddress.ip_network(member.get("cidr", ""))
    except ValueError:
        problems.append(f"{where}.cidr: the range of its network, e.g. 10.21.0.0/24")
    planes = member.get("planes", {})
    if not planes or any(p not in PLANES or r not in ROLES for p, r in planes.items()):
        problems.append(f"{where}.planes: each plane ({', '.join(sorted(PLANES))}) with its role (tenant or shared)")
    if member.get("inputs") and not (base / member["inputs"]).exists():
        problems.append(f"{where}.inputs: no file {member['inputs']}")
    if kind_type == "existing" and (member.get("inputs") or member.get("values")):
        problems.append(f"{where}: an existing project takes no inputs: lz only attaches it to the planes")
    if kind_type == "kubernetes" and not member.get("cluster_cloud"):
        problems.append(f"{where}.cluster_cloud: the clouds.yaml entry of the cluster's application credential")
    if member.get("provides") and (kind != "shared-services" or set(member["provides"]) - PROVIDED):
        problems.append(f"{where}.provides: a shared service's values for the tenants, among {', '.join(sorted(PROVIDED))}")
    for consumer in member.get("consumers", []):
        if consumer not in tenants:
            problems.append(f"{where}.consumers: {consumer} is not a tenant")
    return problems


def backend(config, key):
    """The backend of a stack's state, or None for a local state beside the stack."""
    state = config.get("state")
    if not state:
        return None
    return {"type": state["backend"], "config": state.get("config", {}), "key": state["key"].format(stack=key)}


def members(config):
    """The tenants and the shared services, with the stack lz deploys for each (None: existing)."""
    found = [(t, TENANT_STACKS[t["type"]]) for t in config["tenants"]]
    return found + [(s, SERVICE_STACKS[s["type"]]) for s in config.get("shared-services", [])]


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
    for member, path in members(config):
        name = member["name"]
        attachments[name] = {"stack": name, "cidr": member["cidr"], "planes": member["planes"], "existing": path is None}
        if path is None:
            continue
        stacks[name], states[name] = path, name
        own = [str(base / member["inputs"])] if member.get("inputs") else []
        options["stacks"][name] = {"inputs": own, "backend": backend(config, name)}
    # The ranges each plane routes to: those of the attachments that take it as tenants.
    ranges = {}
    for spec in attachments.values():
        for plane, role in spec["planes"].items():
            if role == "tenant":
                ranges.setdefault(plane, []).append(spec["cidr"])
    options["planes"]["tenant_ranges"] = ranges
    options["planes"]["own_inputs"] = True  # the planes themselves are in the stack's own inputs file
    deployed = [m for m, path in members(config) if path]
    options["clusters"] = [m["name"] for m in deployed if m["type"] == "kubernetes"]
    services = [s for s in config.get("shared-services", []) if s["type"] != "existing"]
    sequence = ["prep", "planes"]
    sequence += ["deploy-egress"] if "egress" in stacks else []
    sequence += ["deploy-entry-point"]
    sequence += [f"tenant-{t['name']}" for t in config["tenants"] if t["type"] != "existing"]
    sequence += [f"service-{s['name']}" for s in services]  # after the tenants: their consumers' sources
    sequence += ["deploy-egress-tenants"] if "egress" in stacks else []
    sequence += ["transit", "deploy-publish"]
    sequence += [f"cluster-{m['name']}" for m in deployed if m["type"] == "kubernetes"]
    options["from"] = {"apply": sequence}  # lz upgrade: the same steps, applied over the deployed release
    return Scenario(
        name="deploy", profile=config["profile"], modes=[config["mode"]], stacks=stacks, states=states,
        sequences={"deploy": sequence}, options=options,
    )  # fmt: skip


def prepare(ctx, config):
    """The context of a deployment: the values given to the tenants, the settings lz reads, and
    the steps of each tenant and shared service."""
    given = provided(config)
    ctx.external = {"receiver": {"receiver_url": given["receiver"]}}
    if given.get("resolver"):
        ctx.external["resolver"] = {"resolver": given["resolver"]}
    if given.get("certificates"):
        ctx.external["acme"] = {"certificates": given["certificates"]}
    ctx.config.setdefault("clouds", {}).update(config.get("clouds", {}))
    for member, _ in members(config):
        ctx.config["clouds"][member["name"]] = member["cloud"]
    ctx.config.setdefault("site", config["site"])
    ctx.config.setdefault("ssh_user", config["admin"]["ssh_user"])
    ctx.config.setdefault("ssh_key", config["admin"]["ssh_key"])
    base = Path(config["base"])
    for key, stack in config.get("stacks", {}).items():
        if stack.get("inputs") and key in ctx.scenario.stacks and not ctx.runner.dry_run:
            link = ctx.root / ctx.scenario.stacks[key] / OWN_INPUTS
            link.unlink(missing_ok=True)
            link.symlink_to(base / stack["inputs"])
    register(config)


# The guide sections of the steps of each tenant and shared service.
MEMBER_GUIDES = {
    "tenant": ["docs/reference/test-procedure.md#4-tenants-web-and-private", "docs/getting-started/README.md#4-tenants"],
    "service": ["docs/reference/test-procedure.md#6-shared-cluster", "stacks/shared/kubernetes/README.md#usage"],
    "service-vm": ["docs/reference/test-procedure.md#2-shared-services", "stacks/shared/vm/README.md#usage"],
    "cluster": ["docs/reference/test-procedure.md#7-published-cluster", "docs/guides/kubernetes-lifecycle.md"],
}
# The steps of the shared stacks that depend on the tenants.
SHARED_GUIDES = {
    "deploy-egress": ["stacks/shared/egress/README.md#usage"],
    "deploy-entry-point": ["docs/getting-started/README.md#3-entry-point"],
    "deploy-egress-tenants": ["stacks/shared/egress/README.md#usage"],
    "deploy-publish": ["docs/guides/publish-a-domain.md"],
}


def register(config):
    """The steps of the tenants and shared services of a configuration (a deployment, or the
    scenario of the reference): tenant-<name>, service-<name>, cluster-<name>, and the steps of
    the shared stacks that depend on them."""
    for member, path in members(config):
        if path is None:
            continue
        kind = "tenant" if member in config["tenants"] else "service"
        STEPS[f"{kind}-{member['name']}"] = partial(tenant_step if kind == "tenant" else service_step, tenant=member,
                                                    config=config)  # fmt: skip
        guide = "service-vm" if kind == "service" and member["type"] == "vm" else kind
        GUIDES[f"{kind}-{member['name']}"] = MEMBER_GUIDES[guide]
        if member["type"] == "kubernetes":
            STEPS[f"cluster-{member['name']}"] = partial(cluster_step, tenant=member)
            GUIDES[f"cluster-{member['name']}"] = MEMBER_GUIDES["cluster"]
    STEPS["deploy-egress"] = deploy_egress
    STEPS["deploy-entry-point"] = deploy_entry_point
    STEPS["deploy-egress-tenants"] = partial(deploy_egress_tenants, tenants=config["tenants"])
    STEPS["deploy-publish"] = partial(deploy_publish, tenants=config["tenants"])
    GUIDES.update(SHARED_GUIDES)


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


def tenant_step(ctx, report, tenant, config=None):
    """A tenant: its values, then what the landing zone gives it (its attachment, the receiver, the
    sources of the entry point, a resolver, its certificates), which win; its own inputs file comes
    before both. A Kubernetes tenant with its bootstrap instance until its cluster exists."""
    name = tenant["name"]
    inputs = dict(tenant.get("values", {}))
    inputs.update(cloud=ctx.cloud(name), plane_attachment=attachment(ctx, tenant.get("attachment", name)),
                  monitoring=monitoring(ctx))  # fmt: skip
    settings = certificates(ctx, name)
    if settings is not None:
        inputs["certificates"] = settings
    if tenant["type"] == "vm":
        inputs["name"] = name  # the vm stack's resources are named after it
        inputs["web_cidr"] = tenant["cidr"]  # the range of its attachment
    else:
        inputs["cluster_cidr"] = tenant["cidr"]
    if "publication" in tenant["planes"]:
        inputs["edge_sources"] = edge_sources(ctx)
    if tenant.get("resolver") and ctx.has("resolver"):  # a tenant without egress: the resolver behind a plane
        inputs["dns_nameservers"] = [ctx.value("resolver", "resolver")]
    if tenant.get("egress_proxy") and ctx.has("egress"):  # out through the shared egress, no egress router
        inputs.update(shared_egress={"proxy": ctx.value("egress", "proxy")}, egress_network=None)
    if tenant["type"] == "kubernetes":
        inputs["bootstrap"] = not kubeconfig(ctx, name).exists()
    ctx.set_inputs(name, **inputs)
    ctx.apply(name)
    if tenant["type"] == "kubernetes" and inputs["bootstrap"]:
        wait_for_bootstrap(ctx, name)
    elif tenant["type"] == "vm" and not tenant.get("egress_proxy"):  # those wait for their admission on the egress
        ctx.wait_for_instances(ctx.value(name, "bastion"), ctx.instances(name))


def certificates(ctx, name):
    """The ACME settings of a tenant or a shared service: those a service provides, or the outputs
    of the test ACME authority of the reference; None without either (demonstration mode)."""
    if not ctx.has("acme"):
        return None
    every = ctx.value("acme", "certificates")
    if ctx.runner.dry_run:
        return f"<acme.certificates.{name}>"
    return every.get(name) if isinstance(every, dict) else None


def service_step(ctx, report, tenant, config):
    """A shared service deployed by lz (a shared cluster, or virtual machines): admitted to its
    consumers, the tenants it names, by their addresses on the internal services plane."""
    name = tenant["name"]
    consumers = []
    for consumer in tenant.get("consumers", []):
        member = next(t for t in config["tenants"] if t["name"] == consumer)
        existing = member["type"] == "existing"
        if not existing and not ctx.tofu.deployed(ctx.stack(consumer)):
            ctx.runner.echo(f"{name}: consumer {consumer} not deployed yet, admitted when its step runs this one again")
            continue
        sources = member.get("internal_sources", []) if existing else ctx.value(consumer, "internal_sources")
        consumers += sources if isinstance(sources, list) else [sources]  # a placeholder in a dry run
    inputs = dict(tenant.get("values", {}))
    inputs.update(cloud=ctx.cloud(name), plane_attachment=attachment(ctx, tenant.get("attachment", name)),
                  monitoring=monitoring(ctx), consumers=consumers)  # fmt: skip
    if tenant["type"] == "vm":
        inputs.update(name=name, cidr=tenant["cidr"])  # the vm stack's resources are named after it
    else:
        inputs.update(cluster_cidr=tenant["cidr"], bootstrap=not kubeconfig(ctx, name).exists())
    settings = certificates(ctx, name)
    if settings is not None:
        inputs["certificates"] = settings
    ctx.set_inputs(name, **inputs)
    ctx.apply(name)
    if tenant["type"] == "vm":
        ctx.wait_for_instances(ctx.value(name, "bastion"), ctx.instances(name))
    elif inputs["bootstrap"]:
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
    for name in declared:  # admitted: their instances install their packages through the proxy
        ctx.wait_for_instances(ctx.value(name, "bastion"), ctx.instances(name))


def deploy_publish(ctx, report, tenants):
    """The domains of the tenants on the entry point: each tenant's request into the reviewed
    domains file, then the publication (ADR-0016, D5)."""
    import os  # noqa: PLC0415

    for tenant in tenants:
        if "publication" not in tenant["planes"] or tenant["type"] == "existing":
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
    credential = ctx.work / f"{name}-clouds.yaml"  # written by step prep in a campaign
    entry = tenant.get("cluster_cloud") or ctx.config.get("cluster_clouds", {}).get(name)
    if not credential.exists() and entry:
        cluster_credential(ctx, entry, credential)
    kubectl = create_cluster(ctx, name, credential, config)
    if tenant.get("demo"):  # the services the stack demonstrates (its demo directory)
        from .steps.shared import deploy_demos  # noqa: PLC0415

        deploy_demos(ctx, kubectl)
