"""One place to run the commands of a campaign: printed as they run, or only printed (dry run)."""

import json
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
            self.echo("$ " + shlex.join(cmd))
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


class Tofu:
    """OpenTofu or Terraform on the stacks of a campaign."""

    def __init__(self, runner, tool="tofu", root="."):
        self.runner = runner
        self.tool = tool
        self.root = root

    def _cmd(self, stack, *args):
        return [self.tool, f"-chdir={stack}", *args]

    def init(self, stack):
        return self.runner.run(self._cmd(stack, "init", "-input=false", "-no-color"), cwd=self.root, quiet=True)

    def plan_exitcode(self, stack):
        """0: no change, 2: changes, 1: error (plan -detailed-exitcode)."""
        cmd = self._cmd(stack, "plan", "-detailed-exitcode", "-input=false", "-no-color")
        return self.runner.run(cmd, cwd=self.root, check=False).returncode

    def deployed(self, stack):
        """Whether the stack's state holds resources (a dry run lists the commands of every stack)."""
        result = self.runner.run(self._cmd(stack, "state", "list"), cwd=self.root, check=False, quiet=True)
        return self.runner.dry_run or (result.returncode == 0 and bool(result.stdout.strip()))

    def output(self, stack, name):
        result = self.runner.run(self._cmd(stack, "output", "-json", name), cwd=self.root, quiet=True)
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
