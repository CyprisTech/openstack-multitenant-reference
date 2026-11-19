"""A scenario: the profile, the plane modes, the stacks and the sequences of steps (TOML)."""

import tomllib
from dataclasses import dataclass, field
from pathlib import Path

MODES = ("gateway", "interface")


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
    return Scenario(
        name=path.stem,
        profile=data["profile"],
        modes=list(data["modes"]),
        stacks=dict(data["stacks"]),
        sequences=dict(data["sequences"]),
        options=dict(data.get("options", {})),
    )
