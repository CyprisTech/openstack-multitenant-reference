#!/usr/bin/env python3
"""Test campaign of the reference, by profile (ADR-0014).

    tests/campaign/run.py private-cloud --mode gateway full
    tests/campaign/run.py public-cloud planes edge
    tests/campaign/run.py private-cloud --dry-run full

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

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
sys.path.insert(0, str(HERE))

from campaign import preflight  # noqa: E402
from campaign import scenario as scenarios  # noqa: E402
from campaign.context import Context  # noqa: E402
from campaign.report import Report  # noqa: E402
from campaign.steps import load  # noqa: E402
from campaign.tools import Runner  # noqa: E402


# A recorded step runs in its own process under asciinema; its result comes back in a file.
INNER = "CAMPAIGN_INNER"
INNER_REPORT = "step-report.json"


def record_step(args, scenario, mode, name, ctx, entry):
    """Runs one step under asciinema (one cast per step), then takes its result."""
    casts = ctx.work / "casts"
    casts.mkdir(exist_ok=True)
    cast = casts / f"{time.strftime('%m%d-%H%M', time.gmtime())}-{mode}-{name}.cast"
    inner = [sys.executable, str(Path(__file__).resolve()), scenario.name, name, "--mode", mode,
             "--config", args.config, "--work", args.work]  # fmt: skip
    (ctx.work / INNER_REPORT).unlink(missing_ok=True)
    subprocess.run(["asciinema", "rec", "-q", "--overwrite", "--cols", "130", "--rows", "40", "--title", name,
                    "-c", shlex.join(inner), str(cast)], env=dict(os.environ, **{INNER: "1"}), check=False)  # fmt: skip
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
    parser.add_argument("--no-preflight", action="store_true", help="skip the check of the credentials")
    args = parser.parse_intermixed_args(argv)

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

    runner = Runner(dry_run=args.dry_run)
    ctx = Context(scenario, mode, config, runner, ROOT, Path(args.work) / f"{scenario.name}-{mode}")
    report = Report(scenario.name, scenario.profile, mode, args.dry_run)
    steps = load()
    names = scenario.expand(args.items)
    if not (args.dry_run or args.no_preflight or os.environ.get(INNER)):
        try:
            preflight.check(ctx, names)
        except Exception as error:  # nothing has run: say why and stop
            ctx.notify(f"campaign {scenario.name} {mode} not started: {error}")
            return 1

    for name in names:
        entry = report.step(name)
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
        if entry.status == "failed":
            if not os.environ.get(INNER):  # a recorded step: the outer run tells the operator
                ctx.notify(f"campaign {scenario.name} {mode} stopped at step {name} after {entry.seconds / 60:.0f} min")
            break

    print("\n" + report.summary())
    return 0 if report.ok else 1


if __name__ == "__main__":
    sys.exit(main())
