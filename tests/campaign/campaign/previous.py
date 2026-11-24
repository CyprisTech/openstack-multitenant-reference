"""The upgrade from the previous release (spec docs/specs/upgrades.md, parts 3 to 5).

The previous release is deployed in a git worktree at its tag, with its own run.py and the steps
of options.from.previous; the same worktree then checks out the commit under test. The states and
the inputs, outside git, stay where they are, as for a user who pulls a new release. The
campaign then applies the new release over them, stack by stack (step migrate).
"""

import json
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

from .context import StepFailed

DONE = "previous-deployed"  # in the work directory: the previous release is deployed


def tree(work):
    """The worktree of the run, beside its work directory (outside both checkouts)."""
    return Path(work).parent / f"{Path(work).name}-tree"


def git(runner, *args, cwd):
    return runner.run(["git", *args], cwd=cwd, quiet=True)


def commit_under_test(runner, root):
    """The commit of the checkout that runs the campaign; its tracked files must be committed,
    since the worktree only sees commits."""
    changed = git(runner, "status", "--porcelain", "--untracked-files=no", cwd=root).stdout.strip()
    if changed and not runner.dry_run:
        raise StepFailed(f"commit the changes first: the upgrade checks out a commit\n{changed}")
    return git(runner, "rev-parse", "HEAD", cwd=root).stdout.strip() or "HEAD"


def prepare(runner, root, path, tag):
    """The worktree at the tag of the previous release, created once."""
    if not (path / ".git").exists():
        git(runner, "worktree", "add", "--detach", str(path), tag, cwd=root)
    elif not runner.dry_run:
        head = git(runner, "rev-parse", "HEAD", cwd=path).stdout.strip()
        wanted = git(runner, "rev-parse", f"{tag}^{{commit}}", cwd=root).stdout.strip()
        if head != wanted:
            raise StepFailed(f"{path} is not at {tag}: remove the worktree (git worktree remove) to start again")


# The inputs of the operator, outside git: they stay in the operator's checkout from one release to
# the next, so the worktree gets a copy of them.
LOCAL_INPUTS = ("stacks/**/terraform.tfvars", "tests/fixtures/**/terraform.tfvars")


def copy_local_inputs(runner, root, path):
    """The terraform.tfvars of the stacks and fixtures, copied into the worktree when missing."""
    for pattern in LOCAL_INPUTS:
        for source in Path(root).glob(pattern):
            target = path / source.relative_to(root)
            if target.parent.exists() and not target.exists():
                if not runner.dry_run:
                    shutil.copyfile(source, target)
                runner.echo(f"input copied: {source.relative_to(root)}")


STEP_LINE = re.compile(r"^== \[[0-9:]+ \S+\] (\S+)")


def follow(cmd, cwd, echo, notify):
    """Runs the previous release's run.py, its output printed as it comes. Its steps are told to the
    operator here: a run.py before v0.6 tells only its stops."""
    current, started = None, 0.0
    with subprocess.Popen(cmd, cwd=cwd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                          stderr=subprocess.STDOUT, text=True, bufsize=1) as process:  # fmt: skip
        for line in process.stdout:
            echo(line.rstrip("\n"))
            match = STEP_LINE.match(line)
            if match:
                if current:
                    notify(f"previous release: step {current} ok in {(time.monotonic() - started) / 60:.0f} min")
                current, started = match.group(1), time.monotonic()
                notify(f"previous release: step {current} started")
    return process.returncode


def deploy(runner, path, scenario, mode, steps, config, work, record=False, notify=None):
    """The previous release, with its own run.py: deployment steps only, no acceptance."""
    cmd = [sys.executable, str(path / "tests/campaign/run.py"), scenario, *steps, "--mode", mode,
           "--config", str(config), "--work", str(Path(work).parent)]  # fmt: skip
    if record:
        cmd.append("--record")
    if runner.dry_run or notify is None:
        returncode = runner.run(cmd, cwd=path, check=False, stream=True).returncode
    else:
        runner.echo("$ " + " ".join(cmd))
        returncode = follow(cmd, path, runner.echo, notify)
    if returncode != 0:
        raise StepFailed(f"the previous release did not deploy (its report: {Path(work) / 'report.json'})")
    report = Path(work) / "report.json"
    if report.exists():
        report.rename(Path(work) / "report-previous.json")


def checkout(runner, path, commit):
    git(runner, "checkout", "--detach", commit, cwd=path)


def run(runner, root, work, scenario, mode, tag, steps, config, record=False, notify=None):
    """Deploys the previous release once, then checks out the commit under test. Returns the
    worktree, the repository root of the rest of the run."""
    work = Path(work)
    work.mkdir(parents=True, exist_ok=True)
    path = tree(work)
    commit = commit_under_test(runner, root)
    if not (work / DONE).exists():
        prepare(runner, root, path, tag)
        copy_local_inputs(runner, root, path)
        runner.echo(f"previous release {tag} in {path}: {' '.join(steps)}")
        if notify:
            notify(f"campaign {scenario} {mode}: previous release {tag} deploying ({len(steps)} steps)")
        deploy(runner, path, scenario, mode, steps, config, work, record, notify)
        if not runner.dry_run:
            (work / DONE).write_text(json.dumps({"tag": tag}) + "\n")
    checkout(runner, path, commit)
    copy_local_inputs(runner, root, path)  # those of the stacks this release adds
    runner.echo(f"{path} at {commit[:12]}: the new release applies over the states of {tag}")
    return path


def changes(plan):
    """The resources a plan (show -json) replaces, destroys and creates, by address."""
    found = {"replaced": [], "destroyed": [], "created": [], "updated": []}
    for change in plan.get("resource_changes", []):
        actions = change.get("change", {}).get("actions", [])
        if "delete" in actions and "create" in actions:
            found["replaced"].append(change["address"])
        elif actions == ["delete"]:
            found["destroyed"].append(change["address"])
        elif actions == ["create"]:
            found["created"].append(change["address"])
        elif actions == ["update"]:
            found["updated"].append(change["address"])
    return found


class Migration:
    """What the upgrade does to each stack: the plan's replacements and destructions, and the
    requests that failed during its apply. The draft of the migration notes."""

    def __init__(self, ctx, loads=()):
        self.ctx = ctx
        self.loads = list(loads)
        # A step migrate run again (after a failure) adds to what the earlier attempts found.
        found = ctx.work / "migration.json"
        self.stacks = json.loads(found.read_text()) if found.exists() and not ctx.runner.dry_run else {}
        self._counts = None

    def counts(self):
        return [(load.ok, load.failed) for load in self.loads]

    def plan(self, key, stack):
        """The plan of a deployed stack before its apply, kept in the work directory."""
        plans = self.ctx.work / "plans"
        plans.mkdir(exist_ok=True)
        out = plans / f"{key}.tfplan"
        tofu = self.ctx.tofu
        cmd = tofu._cmd(stack, "plan", "-input=false", "-no-color", f"-out={out}", *stack.var_files())
        text = self.ctx.runner.run(cmd, cwd=self.ctx.root, env=stack.env(), check=False, quiet=True)
        found = {"replaced": [], "destroyed": [], "created": [], "updated": []}
        if not self.ctx.runner.dry_run:
            kept = plans / f"{key}.txt"
            if kept.exists():  # the plan of an earlier attempt
                kept.rename(plans / f"{key}.{len(list(plans.glob(f'{key}.*.txt'))) + 1}.txt")
            kept.write_text(text.stdout + text.stderr)
            if text.returncode != 0:
                raise StepFailed(f"plan failed on {key} (plans/{key}.txt)")
            show = self.ctx.runner.run(tofu._cmd(stack, "show", "-json", str(out)), cwd=self.ctx.root,
                                       env=stack.env(), quiet=True)  # fmt: skip
            found = changes(json.loads(show.stdout))
        earlier = self.stacks.get(key, {})
        merged = {k: sorted(set(earlier.get(k, [])) | set(v)) for k, v in found.items()}
        self.stacks[key] = dict(merged, requests_failed=earlier.get("requests_failed", {}))
        self._counts = self.counts()
        self.ctx.runner.echo(f"{key}: {len(found['replaced'])} replaced, {len(found['destroyed'])} destroyed, "
                             f"{len(found['created'])} created, {len(found['updated'])} updated")  # fmt: skip

    def applied(self, key):
        """After the apply of a stack: the requests that failed during it."""
        if key not in self.stacks or self._counts is None:
            return
        failed = self.stacks[key]["requests_failed"]
        if not isinstance(failed, dict):  # migration.json of an earlier version: one total
            failed = {"total": failed} if failed else {}
        for load, now, before in zip(self.loads, self.counts(), self._counts, strict=True):
            if now[1] > before[1]:
                label = getattr(load, "label", "requests")
                failed[label] = failed.get(label, 0) + now[1] - before[1]
        self.stacks[key]["requests_failed"] = failed
        self._counts = None

    def write(self):
        if not self.ctx.runner.dry_run:
            (self.ctx.work / "migration.json").write_text(json.dumps(self.stacks, indent=2) + "\n")

    def summary(self):
        """One line per stack that loses or replaces something, or failed requests."""
        lines = []
        for key, found in self.stacks.items():
            parts = [f"{len(found[k])} {k}" for k in ("replaced", "destroyed") if found[k]]
            failed = found["requests_failed"]
            for label, count in (failed.items() if isinstance(failed, dict) else [("requests", failed)]):
                if count:
                    parts.append(f"{count} failed ({label})")
            if parts:
                lines.append(f"{key}: {', '.join(parts)}")
        return lines

