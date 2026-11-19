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
import os
import sys
import time
import tomllib
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
sys.path.insert(0, str(HERE))

from campaign import scenario as scenarios  # noqa: E402
from campaign.context import Context  # noqa: E402
from campaign.report import Report  # noqa: E402
from campaign.steps import load  # noqa: E402
from campaign.tools import Runner  # noqa: E402


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("scenario", help="a scenario of scenarios/, by name (private-cloud, public-cloud)")
    parser.add_argument("items", nargs="*", default=["full"], help="sequences or steps (default: full)")
    parser.add_argument("--mode", help="plane mode; default: the first mode of the scenario")
    parser.add_argument("--config", default=str(HERE / "campaign.local.toml"), help="maintainers' configuration")
    parser.add_argument("--work", default=str(HERE / "work"), help="outputs of the runs (git-ignored)")
    parser.add_argument("--dry-run", action="store_true", help="print the commands without running them")
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
            function(ctx, entry)
            entry.status = "ok"
        except Exception as error:  # a step fails in any way; the campaign stops and says why
            entry.status = "failed"
            entry.error = str(error)
            print(f"step {name} failed: {error}", file=sys.stderr)
        finally:
            entry.seconds = round(time.monotonic() - started, 1)
            report.write(ctx.work / "report.json")
        if entry.status == "failed":
            ctx.notify(f"campaign {scenario.name} {mode} stopped at step {name} after {entry.seconds / 60:.0f} min")
            break

    print("\n" + report.summary())
    return 0 if report.ok else 1


if __name__ == "__main__":
    sys.exit(main())
