#!/usr/bin/env python3
"""Test campaign of the reference, by profile (ADR-0014).

    tests/campaign/run.py private-cloud --mode gateway full
    tests/campaign/run.py public-cloud planes edge
    tests/campaign/run.py private-cloud --dry-run full
    tests/campaign/run.py private-cloud --mode interface --from v0.5.1     # the upgrade

The scenario (scenarios/<name>.toml) names the stacks and the sequences; the maintainers'
configuration (clouds.yaml entries, administrator addresses) is in campaign.local.toml, not
versioned. Python 3.11 or later, standard library only.
"""

import argparse
import json
import os
import shlex
import subprocess
import sys
import time
import tomllib
from pathlib import Path

from campaign import preflight, previous
from campaign import scenario as scenarios
from campaign.context import Context
from campaign.report import Report
from campaign.steps import GUIDES, load
from campaign.tools import Runner

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent

# A recorded step runs in its own process under asciinema; its result comes back in a file.
INNER = "CAMPAIGN_INNER"
INNER_REPORT = "step-report.json"
# What a recorded step prints, kept beside its cast: the outer run prints it in its own output.
INNER_OUTPUT = "step-output.txt"


class Tee:
    """A stream that writes to the terminal (the recording) and to a file."""

    def __init__(self, stream, file):
        self.stream, self.file = stream, file

    def write(self, text):
        self.file.write(text)
        return self.stream.write(text)

    def flush(self):
        self.file.flush()
        self.stream.flush()

    def __getattr__(self, name):
        return getattr(self.stream, name)


def record_step(args, scenario, mode, name, ctx, entry):
    """Runs one step under asciinema (one cast per step), then takes its result."""
    casts = ctx.work / "casts"
    casts.mkdir(exist_ok=True)
    cast = casts / f"{time.strftime('%m%d-%H%M', time.gmtime())}-{mode}-{name}.cast"
    inner = [sys.executable, str(Path(__file__).resolve()), scenario.name, name, "--mode", mode,
             "--config", args.config, "--work", args.work, "--root", str(ctx.root)]  # fmt: skip
    (ctx.work / INNER_REPORT).unlink(missing_ok=True)
    (ctx.work / INNER_OUTPUT).unlink(missing_ok=True)
    subprocess.run(["asciinema", "rec", "-q", "--overwrite", "--cols", "130", "--rows", "40", "--title", name,
                    "-c", shlex.join(inner), str(cast)], env=dict(os.environ, **{INNER: "1"}), check=False)  # fmt: skip
    output = ctx.work / INNER_OUTPUT
    if output.exists():
        print(output.read_text(errors="replace"), end="", flush=True)
    try:
        inner_entry = json.loads((ctx.work / INNER_REPORT).read_text())["steps"][-1]
    except (OSError, ValueError, IndexError, KeyError) as error:
        raise RuntimeError(f"the recorded step left no result ({error}); cast: {cast}") from error
    entry.measures.update(inner_entry.get("measures", {}))
    ctx.durations.extend(json.loads((ctx.work / INNER_REPORT).read_text()).get("durations", []))
    entry.measures["cast"] = cast.name
    if inner_entry.get("status") != "ok":
        raise RuntimeError(inner_entry.get("error") or f"step {name} failed (cast: {cast})")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("scenario", help="a scenario of scenarios/, by name (private-cloud, public-cloud)")
    parser.add_argument("items", nargs="*", default=["full"], help="sequences or steps (default: full)")
    parser.add_argument("--mode", help="plane mode; default: the first mode of the scenario")
    parser.add_argument("--config", default=str(HERE / "campaign.local.toml"), help="maintainers' configuration")
    parser.add_argument("--work", default=str(HERE / "work"), help="outputs of the runs (git-ignored)")
    parser.add_argument("--dry-run", action="store_true", help="print the commands without running them")
    parser.add_argument("--record", action="store_true", help="record each step with asciinema, in <work>/casts")
    parser.add_argument("--no-preflight", action="store_true", help="skip the checks before the first step")
    parser.add_argument("--allow-existing", action="store_true",
                        help="start although the projects hold objects and no state of the campaign does")
    parser.add_argument("--from", dest="previous", metavar="TAG",
                        help="deploy the release TAG first, then upgrade it to this commit (default steps: from-previous)")
    parser.add_argument("--root", help=argparse.SUPPRESS)  # the tree of a recorded step
    args = parser.parse_intermixed_args(argv)
    if args.previous and args.items == ["full"]:
        args.items = ["from-previous"]

    scenario = scenarios.load(HERE / "scenarios" / f"{args.scenario}.toml")
    mode = args.mode or scenario.modes[0]
    if mode not in scenario.modes:
        parser.error(f"mode {mode} is not run by scenario {scenario.name} ({', '.join(scenario.modes)})")
    config = {}
    if Path(args.config).exists():
        with open(args.config, "rb") as f:
            config = tomllib.load(f)
    elif not args.dry_run:
        parser.error(f"no configuration: copy {HERE / 'campaign.local.toml.example'} to {args.config}")

    # Only the clouds.yaml entries named in the configuration may be used: the OS_* variables of
    # the shell would mix with them.
    for variable in [v for v in os.environ if v.startswith("OS_")]:
        del os.environ[variable]
    os.environ["TF_IN_AUTOMATION"] = "1"

    if os.environ.get(INNER):
        work = Path(args.work) / f"{scenario.name}-{mode}"
        work.mkdir(parents=True, exist_ok=True)
        output = open(work / INNER_OUTPUT, "w", buffering=1)
        sys.stdout, sys.stderr = Tee(sys.stdout, output), Tee(sys.stderr, output)

    # A recorded step prints the full output of the tools: the recording is the story of the run.
    runner = Runner(dry_run=args.dry_run, verbose=bool(os.environ.get(INNER)))
    work = Path(args.work) / f"{scenario.name}-{mode}"
    root = Path(args.root) if args.root else ROOT
    if args.previous and previous.tree(work).exists():
        root = previous.tree(work)  # an upgrade started again: its states are in its worktree
    ctx = Context(scenario, mode, config, runner, root, work)
    report = Report(scenario.name, scenario.profile, mode, args.dry_run)
    steps = load()
    names = scenario.expand(args.items)
    if not (args.dry_run or args.no_preflight or os.environ.get(INNER)):
        try:
            preflight.check(ctx, names, allow_existing=args.allow_existing)
        except Exception as error:  # nothing has run: say why and stop
            ctx.notify(f"campaign {scenario.name} {mode} not started: {error}")
            return 1
    if args.previous and not os.environ.get(INNER):
        # The previous release, deployed once in a worktree that then checks out this commit:
        # the rest of the run applies the new release over its states.
        steps_before = scenario.options.get("from", {}).get("previous", [])
        if not steps_before:
            parser.error(f"scenario {scenario.name} has no options.from.previous")
        try:
            root = previous.run(runner, ROOT, work, scenario.name, mode, args.previous, steps_before,
                                Path(args.config).resolve(), record=args.record,
                                notify=ctx.notify if config.get("notify_steps", True) and not args.dry_run else None)  # fmt: skip
        except Exception as error:
            ctx.notify(f"campaign {scenario.name} {mode}: upgrade from {args.previous} stopped: {error}")
            return 1
        ctx = Context(scenario, mode, config, runner, root, work)

    outer = not os.environ.get(INNER)  # a recorded step: the outer run tells the operator
    steps_notified = outer and config.get("notify_steps", True) and not args.dry_run
    campaign_started = time.monotonic()
    if steps_notified:
        ctx.notify(f"campaign {scenario.name} {mode} started: {len(names)} steps")

    for name in names:
        entry = report.step(name)
        if steps_notified:
            ctx.notify(f"{mode}: step {name} started")
        print(f"\n== [{time.strftime('%H:%M:%S', time.gmtime())} {mode}] {name}", flush=True)
        function = steps.get(name)
        if function is None:
            entry.status = "not-ported"
            print(f"(step {name} is not ported yet: tests/campaign/run.sh runs it)")
            continue
        started = time.monotonic()
        try:
            if args.record and not args.dry_run and not os.environ.get(INNER):
                record_step(args, scenario, mode, name, ctx, entry)
            else:
                function(ctx, entry)
            entry.status = "ok"
        except Exception as error:  # a step fails in any way; the campaign stops and says why
            entry.status = "failed"
            entry.error = str(error)
            print(f"step {name} failed: {error}", file=sys.stderr)
        finally:
            entry.seconds = round(time.monotonic() - started, 1)
            report.durations = ctx.durations
            report.write(ctx.work / (INNER_REPORT if os.environ.get(INNER) else "report.json"))
        if entry.status == "ok" and name in GUIDES:
            entry.measures["guide"] = ", ".join(GUIDES[name])
            report.write(ctx.work / (INNER_REPORT if os.environ.get(INNER) else "report.json"))
        if entry.status == "ok" and steps_notified:
            measures = ", ".join(f"{k} {v}" for k, v in entry.measures.items() if k != "cast")
            ctx.notify(f"{mode}: step {name} ok in {entry.seconds / 60:.0f} min" + (f" ({measures})" if measures else ""))
        if entry.status == "failed":
            if outer:
                error = (entry.error or "").strip().splitlines()
                ctx.notify(f"campaign {scenario.name} {mode} stopped at step {name} after {entry.seconds / 60:.0f} min"
                           + (f": {error[0][:200]}" if error else ""))
            break

    if steps_notified and report.ok:
        minutes = (time.monotonic() - campaign_started) / 60
        ctx.notify(f"campaign {scenario.name} {mode} finished in {minutes:.0f} min: every step passed")
    if not os.environ.get(INNER):  # a recorded step: the outer run prints the summary
        print("\n" + report.summary())
    return 0 if report.ok else 1


if __name__ == "__main__":
    sys.exit(main())
