"""What every step receives: the scenario, the configuration, the tools, the work directory."""

import json
import os
import re
import shutil
import time
from contextlib import contextmanager
from pathlib import Path

from .retry import Fatal, retry
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
        self.tofu = Tofu(runner, tool=self.tool, root=self.root)
        self.openstack = OpenStack(runner, ca_cert=config.get("ca_cert") or None)
        self._projects = {}

    @property
    def tool(self):
        return self.config.get("tool", "tofu")

    @property
    def options(self):
        return self.scenario.options

    def setting(self, name):
        """A required setting of the maintainers' configuration; a placeholder in a dry run."""
        if name in self.config:
            return self.config[name]
        if self.runner.dry_run:
            return f"<{name}>"
        raise StepFailed(f"campaign.local.toml has no {name}")

    def notify(self, message):
        """Tells the operator: printed, and given to notify_hook when one is configured."""
        self.runner.echo(message)
        hook = self.config.get("notify_hook")
        if hook and not self.runner.dry_run:
            self.runner.run([hook, message], check=False, quiet=True)

    def timing(self, line):
        if not self.runner.dry_run:
            with (self.work / "timings.txt").open("a") as f:
                f.write(f"{time.strftime('%H:%M:%S', time.gmtime())} {line}\n")

    # --- stacks ---------------------------------------------------------------------------------

    def stack(self, key):
        """Path of a stack of the scenario, relative to the repository root."""
        if key not in self.scenario.stacks:
            raise KeyError(f"stack {key} is not in scenario {self.scenario.name}")
        return self.scenario.stacks[key]

    def has(self, key):
        return key in self.scenario.stacks

    def cloud(self, key):
        """The clouds.yaml entry of a stack's project."""
        entries = self.config.get("clouds", {})
        if key in entries:
            return entries[key]
        if self.runner.dry_run:
            return f"<cloud of {key}>"
        raise StepFailed(f"campaign.local.toml: no clouds.{key}")

    def clouds(self):
        """The clouds.yaml entries of the stacks of the scenario, each once."""
        entries = self.config.get("clouds", {})
        return sorted({entries[k] for k in self.scenario.stacks if k in entries})

    def project_id(self, key):
        """The project ID of a stack's project, asked once per clouds.yaml entry."""
        cloud = self.cloud(key)
        if cloud not in self._projects:
            project = self.openstack.project_id(cloud)
            self._projects[cloud] = project or f"<project of {key}>"
        return self._projects[cloud]

    def output(self, key, name):
        return self.tofu.output(self.stack(key), name)

    def value(self, key, name, *path):
        """An output of a stack, or a value inside it; in a dry run, a placeholder naming it."""
        if self.runner.dry_run:
            self.output(key, name)
            return "<" + ".".join((key, name) + path) + ">"
        value = self.output(key, name)
        for part in path:
            value = value[part]
        return value

    # --- apply ----------------------------------------------------------------------------------

    def _log(self, key):
        logs = self.work / "logs"
        logs.mkdir(exist_ok=True)
        return logs / f"{key}.log"

    def _apply(self, key, extra=()):
        """One apply; its full output in the log, the summary lines printed."""
        cmd = [self.tool, f"-chdir={self.stack(key)}", "apply", "-auto-approve", "-input=false", "-no-color", *extra]
        result = self.runner.run(cmd, cwd=self.root, check=False)
        if not self.runner.dry_run:
            self._log(key).write_text(result.stdout + result.stderr)
            for line in (result.stdout + result.stderr).splitlines():
                if re.search(r"^Apply complete|Error|error", line):
                    self.runner.echo(line)
        return result.returncode

    def apply(self, key, empty_plan=True):
        """Applies a stack, then requires an empty plan (unless empty_plan is false: a scene).

        repair_hook (optional, outside this repository) may clean a known failure of the test
        cloud: given the stack path, it prints extra apply arguments, or fails.
        """
        started = time.monotonic()
        self.tofu.init(self.stack(key))
        status = self._apply(key)
        hook, repairs = self.config.get("repair_hook"), int(self.config.get("repairs", 1))
        attempt = 0
        while status != 0 and hook and attempt < repairs:
            attempt += 1
            self.runner.echo(f"apply failed on {key}: repair {attempt}/{repairs}")
            repair = self.runner.run([hook, self.stack(key)], cwd=self.root, check=False)
            if repair.returncode != 0:
                break
            status = self._apply(key, repair.stdout.split())
            self.timing(f"{key} repaired ({attempt}), apply status={status}")
        if status != 0:
            raise StepFailed(f"apply failed: {key}")
        if not empty_plan:
            return
        plan = self.tofu.plan_exitcode(self.stack(key))
        seconds = round(time.monotonic() - started)
        self.runner.echo(f"{key}: apply {seconds} s, plan after apply exit={plan} (0 = empty)")
        self.timing(f"{key} apply={seconds}s plan={plan}")
        if plan != 0:
            raise StepFailed(f"plan not empty after apply: {key}")

    def destroy(self, key):
        """Destroys a stack; its full output in the log."""
        started = time.monotonic()
        cmd = [self.tool, f"-chdir={self.stack(key)}", "destroy", "-auto-approve", "-no-color"]
        result = self.runner.run(cmd, cwd=self.root, check=False)
        if not self.runner.dry_run:
            self._log(key).write_text(result.stdout + result.stderr)
            for line in (result.stdout + result.stderr).splitlines():
                if re.search(r"Destroy complete|Error", line):
                    self.runner.echo(line)
        self.timing(f"{key} destroy={round(time.monotonic() - started)}s status={result.returncode}")
        if result.returncode != 0:
            raise StepFailed(f"destroy failed: {key}")

    # --- instances ------------------------------------------------------------------------------

    @property
    def ssh_config(self):
        return self.work / "ssh.cfg"

    def on_instance(self, bastion, address, command, check=True, quiet=True):
        """Runs a command on an instance through the bastion of its stack."""
        user = self.setting("ssh_user")
        cmd = ["ssh", "-F", self.ssh_config, "-J", f"{user}@{bastion}", f"{user}@{address}", command]
        return self.runner.run(cmd, check=check, quiet=quiet)

    def wait_for_instances(self, bastion, addresses):
        """Each instance answers through the bastion and cloud-init finished without error.

        cloud-init status exits 1 on an error, 2 on a recoverable one: an error is not retried.
        """
        command = "hostname; cloud-init status --wait >/dev/null; s=$?; cloud-init status | tail -1; exit $s"
        for address in addresses:

            def ready(address=address):
                result = self.on_instance(bastion, address, command, check=False)
                if result.returncode in (0, 2):
                    if result.stdout.strip():
                        self.runner.echo(result.stdout.strip())
                    return True
                if result.returncode == 1:
                    raise Fatal(f"cloud-init error on {address}")
                self.runner.echo(f"  {address} not reachable yet")
                return False

            retry("instance", ready, sleep=self.sleep)

    def sleep(self, seconds):
        """Waits, except in a dry run."""
        if not self.runner.dry_run:
            time.sleep(seconds)

    def instances(self, key):
        """The addresses of the instances of a stack (output instances, a map)."""
        value = self.value(key, "instances")
        return [value] if isinstance(value, str) else list(value.values())

    # --- inputs ---------------------------------------------------------------------------------

    def example(self, key):
        """The profile's example inputs of a stack, if any (examples/<profile>/<stack>.tfvars)."""
        path = self.root / "examples" / self.scenario.profile / f"{key}.tfvars"
        return path if path.exists() else None

    def set_inputs(self, key, **values):
        """Writes the inputs a stack receives from the others; they become its reference inputs."""
        path = self.root / self.stack(key) / INPUTS
        self.runner.echo(f"inputs of {key}: {', '.join(values)}")
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

    def write_private(self, path, text):
        """A file only the user reads (credentials, keys)."""
        if self.runner.dry_run:
            return
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            f.write(text)
