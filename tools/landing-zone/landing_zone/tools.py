"""One place to run the commands of a campaign: printed as they run, or only printed (dry run)."""

import json
import os
import shlex
import subprocess
from dataclasses import dataclass


@dataclass
class Result:
    returncode: int
    stdout: str = ""
    stderr: str = ""


class CommandError(RuntimeError):
    """A command that failed where success was required."""

    def __init__(self, cmd, result):
        super().__init__(f"command failed ({result.returncode}): {shlex.join(cmd)}\n{result.stderr.strip()}")
        self.cmd = cmd
        self.result = result


class Runner:
    """Runs commands, or records them in a dry run.

    In a dry run nothing is executed: every command is appended to `commands` and gets the result
    `fake(cmd)` returns, by default an empty success. With `verbose` (a recorded step), the output of
    every command that is not quiet is printed too, so that the recording shows what the tools said.
    """

    def __init__(self, dry_run=False, echo=print, fake=None, verbose=False):
        self.dry_run = dry_run
        self.verbose = verbose
        self.echo = echo
        self.fake = fake or (lambda cmd: Result(0, ""))
        self.commands = []

    def run(self, cmd, cwd=None, env=None, check=True, quiet=False, input=None, timeout=None, stream=False):
        """`input` goes to the standard input: what must not be printed (secrets) goes there.
        With `stream`, the output is printed line by line as it comes (long scripts), and kept."""
        cmd = [str(c) for c in cmd]
        if not quiet:
            # The data directory of a tenant that shares its stack's directory, as a shell would show it.
            data = f"TF_DATA_DIR={env['TF_DATA_DIR']} " if env and env.get("TF_DATA_DIR") else ""
            self.echo("$ " + data + shlex.join(cmd))
        if self.dry_run:
            self.commands.append((cmd, str(cwd) if cwd else None))
            result = self.fake(cmd)
        elif stream:
            result = self._stream(cmd, cwd, env)
        else:
            try:
                done = subprocess.run(cmd, cwd=cwd, env=env, capture_output=True, text=True, input=input, timeout=timeout)
                result = Result(done.returncode, done.stdout, done.stderr)
            except subprocess.TimeoutExpired:
                result = Result(124, "", f"timed out after {timeout} s")
            if self.verbose and not quiet:
                for text in (result.stdout, result.stderr):
                    if text.strip():
                        self.echo(text.rstrip("\n"))
        if check and result.returncode != 0:
            raise CommandError(cmd, result)
        return result


    def _stream(self, cmd, cwd, env):
        lines = []
        with subprocess.Popen(cmd, cwd=cwd, env=env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                              stderr=subprocess.STDOUT, text=True, bufsize=1) as process:  # fmt: skip
            for line in process.stdout:
                self.echo(line.rstrip("\n"))
                lines.append(line)
        return Result(process.returncode, "".join(lines), "")


class Stack(str):
    """The path of a stack from the repository root and, when several tenants share its
    directory, the name of this one: its own state (<name>.tfstate, a local backend), its own
    data directory (.terraform/tenant-<name>, so that several are initialised at once) and its
    own inputs file, as with a backend key per tenant in production."""

    def __new__(cls, path, state=None):
        stack = super().__new__(cls, path)
        stack.state = state
        return stack

    @property
    def inputs(self):
        """The inputs the campaign writes: loaded by tofu by itself, or given with -var-file
        for a tenant of a shared directory (an auto file would be loaded by every tenant)."""
        return f"mode.{self.state}.tfvars.json" if self.state else "mode.auto.tfvars.json"

    @property
    def data_dir(self):
        """The data directory of the tenant, relative to the stack's directory (-chdir)."""
        return f".terraform/tenant-{self.state}" if self.state else None

    def env(self):
        """The environment of a command on this stack: the tenant's data directory, if any."""
        return dict(os.environ, TF_DATA_DIR=self.data_dir) if self.state else None

    def var_files(self):
        """Arguments of plan, apply and destroy for the inputs of a tenant of a shared directory."""
        return [f"-var-file={self.inputs}"] if self.state else []


# A tenant of a shared directory keeps its state in a local backend, at a path of its own.
BACKEND = 'terraform {\n  backend "local" {}\n}\n'


def stack_of(stack):
    return stack if isinstance(stack, Stack) else Stack(stack)


class Tofu:
    """OpenTofu or Terraform on the stacks of a campaign."""

    def __init__(self, runner, tool="tofu", root="."):
        self.runner = runner
        self.tool = tool
        self.root = root

    def _cmd(self, stack, *args):
        return [self.tool, f"-chdir={stack}", *args]

    def init(self, stack):
        """Init; a tenant of a shared directory with its own state and data directory."""
        stack = stack_of(stack)
        args = []
        if stack.state:
            override = os.path.join(self.root, stack, "backend_override.tf")
            if not self.runner.dry_run and not os.path.exists(override):
                with open(override, "w") as f:
                    f.write(BACKEND)
            args = [f"-backend-config=path={stack.state}.tfstate"]
        cmd = self._cmd(stack, "init", "-input=false", "-no-color", *args)
        return self.runner.run(cmd, cwd=self.root, env=stack.env(), quiet=True)

    def plan_exitcode(self, stack):
        """0: no change, 2: changes, 1: error (plan -detailed-exitcode)."""
        stack = stack_of(stack)
        cmd = self._cmd(stack, "plan", "-detailed-exitcode", "-input=false", "-no-color", *stack.var_files())
        return self.runner.run(cmd, cwd=self.root, env=stack.env(), check=False).returncode

    def deployed(self, stack):
        """Whether the stack's state holds resources (a dry run lists the commands of every stack)."""
        stack = stack_of(stack)
        result = self.runner.run(self._cmd(stack, "state", "list"), cwd=self.root, env=stack.env(), check=False, quiet=True)
        return self.runner.dry_run or (result.returncode == 0 and bool(result.stdout.strip()))

    def output(self, stack, name):
        stack = stack_of(stack)
        result = self.runner.run(self._cmd(stack, "output", "-json", name), cwd=self.root, env=stack.env(), quiet=True)
        return json.loads(result.stdout) if result.stdout.strip() else None


class OpenStack:
    """Read-only listings of the openstack client, one clouds.yaml entry per project."""

    def __init__(self, runner, ca_cert=None):
        self.runner = runner
        self.ca_cert = ca_cert

    def _cmd(self, cloud, *args):
        cmd = ["openstack", "--os-cloud", cloud]
        if self.ca_cert:
            cmd += ["--os-cacert", self.ca_cert]
        return cmd + list(args)

    def project_id(self, cloud):
        return self.runner.run(self._cmd(cloud, "token", "issue", "-f", "value", "-c", "project_id"), quiet=True).stdout.strip()

    def ids(self, cloud, *listing, column="ID"):
        """The values of a column of a listing; a failed listing raises, it is not zero objects."""
        out = self.runner.run(self._cmd(cloud, *listing, "-f", "value", "-c", column), quiet=True).stdout
        return [line for line in out.splitlines() if line.strip()]
