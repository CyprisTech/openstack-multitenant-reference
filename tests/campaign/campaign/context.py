"""What every step receives: the scenario, the configuration, the tools, the work directory."""

import json
import shutil
from contextlib import contextmanager
from pathlib import Path

from .tools import OpenStack, Tofu

INPUTS = "mode.auto.tfvars.json"  # loaded by tofu by itself, also by a plain apply


class StepFailed(RuntimeError):
    """A step whose check failed (not a command error)."""


class Context:
    def __init__(self, scenario, mode, config, runner, root, work):
        self.scenario = scenario
        self.mode = mode
        self.config = config
        self.runner = runner
        self.root = Path(root)
        self.work = Path(work)
        self.work.mkdir(parents=True, exist_ok=True)
        self.tofu = Tofu(runner, tool=config.get("tool", "tofu"), root=self.root)
        self.openstack = OpenStack(runner, ca_cert=config.get("ca_cert") or None)

    # --- stacks ---------------------------------------------------------------------------------

    def stack(self, key):
        """Path of a stack of the scenario, relative to the repository root."""
        if key not in self.scenario.stacks:
            raise KeyError(f"stack {key} is not in scenario {self.scenario.name}")
        return self.scenario.stacks[key]

    def has(self, key):
        return key in self.scenario.stacks

    def clouds(self):
        """The clouds.yaml entries of the stacks of the scenario, each once."""
        entries = self.config.get("clouds", {})
        return sorted({entries[k] for k in self.scenario.stacks if k in entries})

    def output(self, key, name):
        return self.tofu.output(self.stack(key), name)

    # --- inputs ---------------------------------------------------------------------------------

    def example(self, key):
        """The profile's example inputs of a stack, if any (examples/<profile>/<stack>.tfvars)."""
        path = self.root / "examples" / self.scenario.profile / f"{key}.tfvars"
        return path if path.exists() else None

    def set_inputs(self, key, **values):
        """Writes the inputs a stack receives from the others; they become its reference inputs."""
        path = self.root / self.stack(key) / INPUTS
        if not self.runner.dry_run:
            path.write_text(json.dumps(values, indent=2) + "\n")
        self._backup(key).unlink(missing_ok=True)

    def _backup(self, key):
        return self.work / f"{key}.inputs.bak"

    @contextmanager
    def scene(self, key):
        """A change of a stack, then its restore, even when the step fails.

        If an earlier run of the scene stopped before restoring, the kept inputs are restored
        first: the scene can be run again.
        """
        path = self.root / self.stack(key) / INPUTS
        backup = self._backup(key)
        if not self.runner.dry_run:
            if backup.exists():
                shutil.copyfile(backup, path)
            else:
                shutil.copyfile(path, backup)
        try:
            yield path
        finally:
            if not self.runner.dry_run:
                shutil.copyfile(backup, path)

    def scene_done(self, key):
        """The stack is applied again with its restored inputs: the kept copy is no longer needed."""
        self._backup(key).unlink(missing_ok=True)
