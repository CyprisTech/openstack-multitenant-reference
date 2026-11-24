"""The upgrade from the previous release, without a cloud."""

import json
import sys
import unittest
from pathlib import Path

from campaign import previous
from campaign.context import StepFailed
from campaign.report import StepReport
from campaign.scenario import load as load_scenario
from campaign.steps import load
from campaign.tools import Result

from tests.test_core import context

HERE = Path(__file__).resolve().parent.parent

PLAN = {"resource_changes": [
    {"address": "a.replaced", "change": {"actions": ["delete", "create"]}},
    {"address": "a.replaced_first", "change": {"actions": ["create", "delete"]}},
    {"address": "a.destroyed", "change": {"actions": ["delete"]}},
    {"address": "a.created", "change": {"actions": ["create"]}},
    {"address": "a.updated", "change": {"actions": ["update"]}},
    {"address": "a.kept", "change": {"actions": ["no-op"]}},
]}  # fmt: skip


class ChangesTest(unittest.TestCase):
    def test_sorts_the_actions_of_a_plan(self):
        found = previous.changes(PLAN)
        self.assertEqual(found["replaced"], ["a.replaced", "a.replaced_first"])
        self.assertEqual(found["destroyed"], ["a.destroyed"])
        self.assertEqual((found["created"], found["updated"]), (["a.created"], ["a.updated"]))


class Counter:
    def __init__(self):
        self.ok = self.failed = 0


def answering(fake):
    """A context whose commands are not run but answered by fake, outside a dry run."""
    ctx = context(dry_run=False)
    ctx.runner.run = lambda cmd, **options: fake([str(c) for c in cmd])
    return ctx


class MigrationTest(unittest.TestCase):
    def test_counts_the_failed_requests_of_each_apply(self):
        ctx = answering(lambda cmd: Result(0, json.dumps(PLAN)) if "show" in cmd else Result(0))
        load = Counter()
        migration = previous.Migration(ctx, [load])
        migration.plan("vm", ctx.stack("vm"))
        load.ok, load.failed = 10, 2
        migration.applied("vm")
        migration.plan("planes", ctx.stack("planes"))
        migration.applied("planes")
        self.assertEqual(migration.stacks["vm"]["requests_failed"], {"requests": 2})
        self.assertEqual(migration.stacks["planes"]["requests_failed"], {})
        self.assertIn("vm: 2 replaced, 1 destroyed, 2 failed (requests)", migration.summary())
        migration.write()
        self.assertTrue((ctx.work / "migration.json").exists())

    def test_a_failed_plan_stops(self):
        ctx = answering(lambda cmd: Result(1, stderr="boom"))
        with self.assertRaisesRegex(StepFailed, "plan failed on vm"):
            previous.Migration(ctx).plan("vm", ctx.stack("vm"))


class WorktreeTest(unittest.TestCase):
    def test_uncommitted_changes_stop_the_upgrade(self):
        ctx = answering(lambda cmd: Result(0, " M run.py"))
        with self.assertRaisesRegex(StepFailed, "commit the changes first"):
            previous.commit_under_test(ctx.runner, ".")

    def test_deploys_once_then_checks_out_the_commit(self):
        ctx = context()
        commands = ctx.runner.commands
        root = previous.run(ctx.runner, ctx.root, ctx.work, "private-cloud", "gateway", "v0.5.1", ["prep"], "c.toml")
        self.assertEqual(root, previous.tree(ctx.work))
        joined = [" ".join(map(str, c)) for c, _ in commands]
        self.assertTrue(any("worktree add --detach" in c and c.endswith("v0.5.1") for c in joined))
        self.assertTrue(any("tests/campaign/run.py private-cloud prep --mode gateway" in c for c in joined))
        self.assertTrue(joined[-1].startswith("git checkout --detach"))


class ScenarioTest(unittest.TestCase):
    def test_the_upgrade_names_steps_of_this_release(self):
        steps = load()
        scenario = load_scenario(HERE / "scenarios" / "private-cloud.toml")
        for name in scenario.options["from"]["apply"] + scenario.expand(["from-previous"]):
            self.assertIn(name, steps)

    def test_migrate_needs_its_steps(self):
        ctx = context()
        with self.assertRaisesRegex(StepFailed, "options.from.apply"):
            load()["migrate"](ctx, StepReport("migrate"))


class FollowTest(unittest.TestCase):
    def test_tells_each_step_of_the_previous_release(self):
        script = "print('== [00:00:01 gateway] prep'); print('apply'); print('== [00:00:02 gateway] planes')"
        told, printed = [], []
        status = previous.follow([sys.executable, "-c", script], ".", printed.append, told.append)
        self.assertEqual(status, 0)
        self.assertEqual(len(printed), 3)
        self.assertEqual(told[0], "previous release: step prep started")
        self.assertTrue(told[1].startswith("previous release: step prep ok in"))
        self.assertEqual(told[2], "previous release: step planes started")


class AttemptsTest(unittest.TestCase):
    def test_a_second_attempt_adds_to_the_first(self):
        ctx = answering(lambda cmd: Result(0, json.dumps(PLAN)) if "show" in cmd else Result(0))
        (ctx.work / "migration.json").write_text(json.dumps(
            {"vm": {"replaced": [], "destroyed": ["a.gone"], "created": [], "updated": [], "requests_failed": 3}}))
        migration = previous.Migration(ctx)
        migration.plan("vm", ctx.stack("vm"))
        self.assertEqual(migration.stacks["vm"]["destroyed"], ["a.destroyed", "a.gone"])
        self.assertEqual(migration.stacks["vm"]["requests_failed"], 3)
