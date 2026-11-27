"""A scenario: the profile, the plane modes, the stacks and the sequences of steps (TOML)."""

import tomllib
from dataclasses import dataclass, field
from pathlib import Path

MODES = ("gateway", "interface")
# What lz deploys for a tenant or a shared service, by type (lz deploy and the scenarios of the
# reference); "existing": nothing, the project is only attached to the planes.
TENANT_STACKS = {"vm": "stacks/tenants/vm", "kubernetes": "stacks/tenants/kubernetes", "existing": None}
SERVICE_STACKS = {"kubernetes": "stacks/shared/kubernetes", "existing": None}


class ScenarioError(ValueError):
    """A scenario that cannot be run as written."""


@dataclass
class Scenario:
    name: str
    profile: str
    modes: list
    stacks: dict  # key => path from the repository root, in the order they are applied
    sequences: dict = field(default_factory=dict)
    options: dict = field(default_factory=dict)  # settings of the steps, by step name
    states: dict = field(default_factory=dict)  # key => state name, for tenants sharing a stack
    members: dict = field(default_factory=dict)  # {"tenants": [...], "shared-services": [...]}, as in a deployment

    def expand(self, items):
        """The steps of a list of sequences or steps, in order; a sequence may name others."""
        steps = []

        def walk(item, path):
            if item in path:
                raise ScenarioError(f"sequence {item} includes itself: {' > '.join(path + [item])}")
            if item in self.sequences:
                for sub in self.sequences[item]:
                    walk(sub, path + [item])
            else:
                steps.append(item)

        for item in items:
            walk(item, [])
        return steps


def load(path):
    """Loads and checks a scenario file."""
    path = Path(path)
    with path.open("rb") as f:
        data = tomllib.load(f)
    for key in ("profile", "modes", "stacks", "sequences"):
        if key not in data:
            raise ScenarioError(f"{path.name}: missing {key}")
    unknown = [m for m in data["modes"] if m not in MODES]
    if unknown:
        raise ScenarioError(f"{path.name}: unknown modes {unknown}, expected {list(MODES)}")
    for name, items in data["sequences"].items():
        if not isinstance(items, list) or not all(isinstance(i, str) for i in items):
            raise ScenarioError(f"{path.name}: sequence {name} must be a list of names")
    # A stack is a path, or { path, state } when several tenants share its directory.
    stacks, states = {}, {}
    for key, value in data["stacks"].items():
        if isinstance(value, dict):
            if "path" not in value or "state" not in value:
                raise ScenarioError(f"{path.name}: stack {key} needs path and state")
            stacks[key], states[key] = value["path"], value["state"]
        else:
            stacks[key] = value
    options = dict(data.get("options", {}))
    members = {"tenants": data.get("tenants", []), "shared-services": data.get("shared-services", [])}
    attachments = options.setdefault("planes", {}).setdefault("attachments", {})
    for kind, types in (("tenants", TENANT_STACKS), ("shared-services", SERVICE_STACKS)):
        for member in members[kind]:
            name = member["name"]
            if member.get("type") not in types:
                raise ScenarioError(f"{path.name}: {kind} {name}: type one of {', '.join(types)}")
            # The name of its attachment in the planes stack: its own, or an earlier one kept.
            attachments[member.get("attachment", name)] = {"stack": name, "cidr": member["cidr"], "planes": member["planes"],
                                                            "existing": types[member["type"]] is None}  # fmt: skip
            if types[member["type"]]:
                stacks[name], states[name] = types[member["type"]], name
    return Scenario(
        name=path.stem,
        profile=data["profile"],
        modes=list(data["modes"]),
        stacks=stacks,
        states=states,
        sequences=dict(data["sequences"]),
        options=options,
        members=members,
    )
