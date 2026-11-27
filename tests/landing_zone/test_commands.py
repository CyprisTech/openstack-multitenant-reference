"""The commands of lz, without a cloud: their arguments, plan and status."""

import importlib.machinery
import importlib.util
import json
import unittest
from pathlib import Path

from test_foundation import context

from landing_zone import commands
from landing_zone.tools import Result

LZ = Path(__file__).resolve().parents[2] / "tools" / "landing-zone" / "lz"


def lz():
    """The entry point, a script without the .py suffix, loaded as a module."""
    loader = importlib.machinery.SourceFileLoader("lz_entry", str(LZ))
    spec = importlib.util.spec_from_loader("lz_entry", loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


class ArgumentsTest(unittest.TestCase):
    def test_the_form_before_lz_is_a_campaign(self):
        _, args = lz().parse(["private-cloud", "--mode", "interface", "planes", "edge"])
        self.assertEqual((args.command, args.scenario, args.mode, args.items), ("campaign", "private-cloud", "interface",
                                                                             ["planes", "edge"]))  # fmt: skip

    def test_each_command_runs_its_steps(self):
        entry = lz()
        self.assertEqual(entry.parse(["try", "private-cloud"])[1].items, ["try"])
        self.assertEqual(entry.parse(["teardown", "private-cloud"])[1].items, ["teardown", "leftovers"])
        self.assertEqual(entry.parse(["upgrade", "private-cloud"])[1].items, ["migrate"])
        self.assertEqual(entry.parse(["campaign", "private-cloud", "--from", "v0.5.1"])[1].items, ["from-previous"])

    def test_plan_takes_no_steps(self):
        with self.assertRaises(SystemExit):
            lz().parse(["plan", "private-cloud", "planes"])


PLAN = {"resource_changes": [
    {"address": "a.kept", "change": {"actions": ["no-op"]}},
    {"address": "a.replaced", "change": {"actions": ["delete", "create"]}},
    {"address": "a.updated", "change": {"actions": ["update"]}},
]}  # fmt: skip


def answer(cmd):
    """vm deployed (three resources) and planned with changes; the other stacks empty."""
    stack = cmd[1].removeprefix("-chdir=") if len(cmd) > 1 else ""
    if cmd[2:4] == ["state", "list"]:
        return Result(0, "a.one\na.two\na.three\n" if stack == "stacks/tenants/vm" else "")
    if cmd[2] == "show":
        return Result(0, json.dumps(PLAN))
    return Result(0)


class PlanStatusTest(unittest.TestCase):
    def test_plan_says_what_each_deployed_stack_would_change(self):
        ctx = context(answer)
        lines, changed = commands.plan(ctx)
        self.assertTrue(changed)
        self.assertIn("planes             not deployed", lines)
        vm = next(line for line in lines if line.startswith("web "))
        self.assertIn("1 replaced", vm)
        self.assertIn("1 updated", vm)
        self.assertIn("   replaced: a.replaced", "\n".join(lines))

    def test_status_counts_the_resources_of_each_stack(self):
        lines = commands.status(context(answer))
        self.assertIn("web                3 resources", lines)
        self.assertIn("receiver           not deployed", lines)


if __name__ == "__main__":
    unittest.main()
