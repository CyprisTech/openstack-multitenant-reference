"""Retries, scenes, the runner's dry run and the end steps, without a cloud."""

import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from campaign import retry  # noqa: E402
from campaign.context import INPUTS, Context, StepFailed  # noqa: E402
from campaign.report import StepReport  # noqa: E402
from campaign.scenario import Scenario  # noqa: E402
from campaign.steps import load  # noqa: E402
from campaign.tools import CommandError, Result, Runner  # noqa: E402


def context(fake=None, dry_run=True, stacks=None, config=None):
    root = Path(tempfile.mkdtemp())
    stacks = stacks or {"planes": "stacks/shared/planes", "vm": "stacks/tenants/vm"}
    for path in stacks.values():
        (root / path).mkdir(parents=True)
    s = Scenario("t", "private-cloud", ["gateway"], stacks, {})
    runner = Runner(dry_run=dry_run, echo=lambda line: None, fake=fake)
    return Context(s, "gateway", config or {}, runner, root, root / "work")


class RetryTest(unittest.TestCase):
    def test_returns_the_first_true_value(self):
        values = iter([None, False, "ok"])
        self.assertEqual(retry.retry(retry.Policy(5, 0), lambda: next(values), sleep=lambda s: None), "ok")

    def test_exceptions_are_retried_then_reported(self):
        def fail():
            raise ConnectionError("refused")

        with self.assertRaisesRegex(retry.GaveUp, "refused"):
            retry.retry(retry.Policy(3, 0), fail, sleep=lambda s: None)

    def test_named_policies_exist(self):
        for name in ("ssh", "octavia", "entry-point"):
            self.assertIn(name, retry.POLICIES)


class RunnerTest(unittest.TestCase):
    def test_dry_run_records_and_fakes(self):
        runner = Runner(dry_run=True, echo=lambda line: None, fake=lambda cmd: Result(2))
        result = runner.run(["tofu", "plan"], check=False)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(runner.commands, [(["tofu", "plan"], None)])

    def test_check_raises_on_failure(self):
        runner = Runner(dry_run=True, echo=lambda line: None, fake=lambda cmd: Result(1, stderr="boom"))
        with self.assertRaisesRegex(CommandError, "boom"):
            runner.run(["false"])

    def test_real_run(self):
        result = Runner(echo=lambda line: None).run([sys.executable, "-c", "print('hi')"])
        self.assertEqual(result.stdout.strip(), "hi")


class SceneTest(unittest.TestCase):
    def test_inputs_are_restored_even_when_the_step_fails(self):
        ctx = context(dry_run=False)
        ctx.set_inputs("vm", exposure="entry-point")
        path = ctx.root / "stacks/tenants/vm" / INPUTS
        with self.assertRaises(RuntimeError):
            with ctx.scene("vm") as inputs:
                inputs.write_text(json.dumps({"exposure": "public"}))
                raise RuntimeError("the change failed")
        self.assertEqual(json.loads(path.read_text()), {"exposure": "entry-point"})

    def test_a_scene_run_again_starts_from_the_kept_inputs(self):
        ctx = context(dry_run=False)
        ctx.set_inputs("vm", exposure="entry-point")
        path = ctx.root / "stacks/tenants/vm" / INPUTS
        backup = ctx.work / "vm.inputs.bak"
        backup.write_text(json.dumps({"exposure": "entry-point"}))
        path.write_text(json.dumps({"exposure": "public"}))  # a run that stopped mid-scene
        with ctx.scene("vm") as inputs:
            self.assertEqual(json.loads(inputs.read_text()), {"exposure": "entry-point"})
        ctx.scene_done("vm")
        self.assertFalse(backup.exists())


class EndStepsTest(unittest.TestCase):
    def test_plans_reports_every_stack_and_fails_on_drift(self):
        steps = load()

        def fake(cmd):
            return Result(2 if "-chdir=stacks/tenants/vm" in cmd else 0)

        ctx = context(fake=fake)
        entry = StepReport("plans")
        with self.assertRaisesRegex(StepFailed, "vm"):
            steps["plans"](ctx, entry)
        self.assertEqual(entry.measures["plans"], "1/2 empty")
        planned = [c for c, _ in ctx.runner.commands if "plan" in c]
        self.assertEqual(len(planned), 2)

    def test_plans_skips_the_stacks_removed_before_the_end(self):
        steps = load()
        ctx = context()
        ctx.scenario.options = {"plans": {"skip": ["vm"]}}
        entry = StepReport("plans")
        steps["plans"](ctx, entry)
        self.assertEqual(entry.measures["plans"], "1/1 empty")

    def test_leftovers_counts_objects_and_failed_listings(self):
        steps = load()

        def fake(cmd):
            if "token" in cmd:
                return Result(0, "p1\n")
            if cmd[3:5] == ["server", "list"]:
                return Result(0, "a\nb\n")
            if cmd[3:5] == ["loadbalancer", "list"]:
                return Result(1, stderr="no plugin")
            if cmd[3:5] == ["security", "group"]:
                return Result(0, "default\n")
            return Result(0, "")

        ctx = context(fake=fake, config={"clouds": {"planes": "hub", "vm": "web"}})
        entry = StepReport("leftovers")
        with self.assertRaisesRegex(StepFailed, "2 leftovers, 2 failed listings"):
            steps["leftovers"](ctx, entry)
        self.assertEqual(entry.measures["leftovers"], 2)

    def test_leftovers_passes_when_projects_are_empty(self):
        steps = load()

        def fake(cmd):
            if "token" in cmd:
                return Result(0, "p1\n")
            if cmd[3:5] == ["security", "group"]:
                return Result(0, "default\n")
            return Result(0, "")

        ctx = context(fake=fake, config={"clouds": {"planes": "hub"}})
        entry = StepReport("leftovers")
        steps["leftovers"](ctx, entry)
        self.assertEqual(entry.measures["leftovers"], 0)


if __name__ == "__main__":
    unittest.main()
