"""The foundation steps and the helpers they use, against a fake cloud."""

import json
import tempfile
import unittest
from pathlib import Path

from campaign import retry
from campaign.context import INPUTS, Context, StepFailed
from campaign.report import StepReport
from campaign.scenario import Scenario
from campaign.steps import load
from campaign.tools import Result, Runner

STACKS = {
    "planes": "stacks/shared/planes",
    "receiver": "tests/fixtures/receiver",
    "entry-point": "stacks/shared/entry-point",
    "vm": "stacks/tenants/vm",
}
OUTPUTS = {
    ("tests/fixtures/receiver", "receiver_url"): "http://10.34.0.5:9090/api/v1/write",
    ("stacks/shared/planes", "attachments"): {"web": {"planes": {"publication": {"routes": []}}}},
    ("stacks/shared/entry-point", "publication_sources"): ["10.20.0.0/24"],
    ("stacks/tenants/vm", "instances"): {"web-1": "10.21.0.11", "web-2": "10.21.0.12"},
    ("stacks/tenants/vm", "bastion"): "192.0.2.10",
}


class FakeRunner(Runner):
    """Runs nothing, like a dry run, but the steps behave as in a real run."""

    def __init__(self, answer):
        super().__init__(dry_run=False, echo=lambda line: None)
        self.answer = answer

    def run(self, cmd, cwd=None, env=None, check=True, quiet=False, input=None, timeout=None, stream=False):
        cmd = [str(c) for c in cmd]
        self.commands.append((cmd, env))
        result = self.answer(cmd)
        if check and result.returncode != 0:
            raise RuntimeError(f"failed: {cmd}")
        return result


def answer_outputs(cmd, extra=None):
    """tofu output -json from OUTPUTS; token issue gives a project ID per cloud."""
    if extra:
        result = extra(cmd)
        if result is not None:
            return result
    if cmd[0] == "tofu" and cmd[2] == "output":
        return Result(0, json.dumps(OUTPUTS[(cmd[1].removeprefix("-chdir="), cmd[4])]))
    if "token" in cmd:
        return Result(0, f"id-of-{cmd[2]}\n")
    return Result(0, "")


def context(answer=answer_outputs, stacks=STACKS, options=None, config=None):
    root = Path(tempfile.mkdtemp())
    for path in stacks.values():
        (root / path).mkdir(parents=True)
    scenario = Scenario("t", "private-cloud", ["gateway"], stacks, {}, options or {})
    config = config or {"clouds": {"planes": "hub", "receiver": "shared", "entry-point": "edge", "vm": "web"},
                        "site": "t1", "ssh_user": "ops", "planes": {"gateway": {"publication": {"mode": "gateway"}}}}  # fmt: skip
    ctx = Context(scenario, "gateway", config, FakeRunner(answer), root, root / "work")
    ctx.sleep = lambda seconds: None
    return ctx


def inputs(ctx, key):
    return json.loads((ctx.root / ctx.stack(key) / INPUTS).read_text())


class PlanesTest(unittest.TestCase):
    def test_attachments_of_the_stacks_of_the_scenario_only(self):
        options = {"planes": {
            "attachments": {
                "web": {"stack": "vm", "cidr": "10.21.0.0/24", "planes": {"publication": "tenant"}},
                "published": {"stack": "published", "cidr": "10.24.0.0/24", "planes": {"publication": "tenant"}},
            },
            "tenant_ranges": {"publication": ["10.21.0.0/16"]},
        }}  # fmt: skip
        ctx = context(options=options)
        load()["planes"](ctx, StepReport("planes"))
        written = inputs(ctx, "planes")
        self.assertEqual(list(written["attachments"]), ["web"])
        self.assertEqual(written["attachments"]["web"]["project_id"], "id-of-web")
        self.assertEqual(written["cloud"], "hub")
        self.assertEqual(written["planes"], {"publication": {"mode": "gateway"}})
        self.assertEqual(written["tenant_ranges"], {"publication": ["10.21.0.0/16"]})

    def test_a_mode_without_planes_in_the_configuration_fails(self):
        ctx = context()
        ctx.mode = "interface"
        with self.assertRaisesRegex(StepFailed, r"\[planes.interface\]"):
            load()["planes"](ctx, StepReport("planes"))


class TenantInputsTest(unittest.TestCase):
    def test_web_gets_the_outputs_of_the_others_and_waits_for_each_instance(self):
        ctx = context()
        load()["web"](ctx, StepReport("web"))
        written = inputs(ctx, "vm")
        self.assertEqual(written["monitoring"], {"receiver": OUTPUTS[("tests/fixtures/receiver", "receiver_url")]})
        self.assertEqual(written["edge_sources"], ["10.20.0.0/24"])
        self.assertEqual(written["plane_attachment"], {"publication": {"routes": []}})
        # Without the test ACME authority, no certificates input: demonstration certificates.
        self.assertNotIn("certificates", written)
        ssh = [c for c, _ in ctx.runner.commands if c[0] == "ssh"]
        self.assertEqual([c[-2] for c in ssh], ["ops@10.21.0.11", "ops@10.21.0.12"])
        self.assertIn("ops@192.0.2.10", ssh[0])


class ApplyTest(unittest.TestCase):
    def test_the_repair_hook_runs_then_the_plan_must_be_empty(self):
        applies = []

        def extra(cmd):
            if "apply" in cmd:
                applies.append(cmd)
                return Result(1 if len(applies) == 1 else 0)
            if cmd[0] == "/repair":
                return Result(0, "-replace=x.y\n")
            if "plan" in cmd:
                return Result(0)
            return None

        ctx = context(lambda cmd: answer_outputs(cmd, extra))
        ctx.config.update(repair_hook="/repair", repairs=2)
        ctx.apply("vm")
        self.assertEqual(len(applies), 2)
        self.assertEqual(applies[1][-1], "-replace=x.y")

    def test_a_plan_with_changes_after_apply_fails(self):
        ctx = context(lambda cmd: answer_outputs(cmd, lambda c: Result(2) if "plan" in c else None))
        with self.assertRaisesRegex(StepFailed, "plan not empty after apply: vm"):
            ctx.apply("vm")

    def test_a_failed_apply_without_a_hook_fails(self):
        ctx = context(lambda cmd: answer_outputs(cmd, lambda c: Result(1) if "apply" in c else None))
        with self.assertRaisesRegex(StepFailed, "apply failed: vm"):
            ctx.apply("vm")


class InstancesTest(unittest.TestCase):
    def test_unreachable_is_retried(self):
        codes = iter([255, 255, 0])
        ctx = context(lambda cmd: Result(next(codes)) if cmd[0] == "ssh" else answer_outputs(cmd))
        ctx.wait_for_instances("192.0.2.10", ["10.21.0.11"])

    def test_a_cloud_init_error_is_not_retried(self):
        ctx = context(lambda cmd: Result(1) if cmd[0] == "ssh" else answer_outputs(cmd))
        with self.assertRaisesRegex(retry.Fatal, "cloud-init error on 10.21.0.11"):
            ctx.wait_for_instances("192.0.2.10", ["10.21.0.11"])
        self.assertEqual(len([c for c, _ in ctx.runner.commands if c[0] == "ssh"]), 1)


class PublishTest(unittest.TestCase):
    def test_first_publication_without_load_in_the_entry_point_project(self):
        ctx = context()
        entry = StepReport("publish")
        load()["publish"](ctx, entry)
        script = [(c, env) for c, env in ctx.runner.commands if c[0] == "scripts/publish-domains.sh"]
        self.assertEqual(script[0][0], ["scripts/publish-domains.sh", "--tool", "tofu"])
        self.assertEqual(script[0][1]["OS_CLOUD"], "edge")
        self.assertNotIn("load", entry.measures)
        self.assertTrue((ctx.work / "published-once").exists())

    def test_a_failed_publication_fails_the_step(self):
        def extra(cmd):
            return Result(1, stderr="state has no published_domains") if cmd[0].startswith("scripts/") else None

        ctx = context(lambda cmd: answer_outputs(cmd, extra))
        with self.assertRaisesRegex(StepFailed, "published_domains"):
            load()["publish"](ctx, StepReport("publish"))

    def test_each_deployed_tenant_requests_its_domains_before_the_publication(self):
        def extra(cmd):
            return Result(0, "module.web\n") if cmd[2:4] == ["state", "list"] else None

        ctx = context(lambda cmd: answer_outputs(cmd, extra))
        load()["publish"](ctx, StepReport("publish"))
        scripts = [c for c, _ in ctx.runner.commands if c[0].startswith("scripts/")]
        self.assertEqual(scripts, [["scripts/request-domains.sh", "stacks/tenants/vm", "--tool", "tofu"],
                                   ["scripts/publish-domains.sh", "--tool", "tofu"]])

    def test_a_tenant_not_deployed_asks_for_nothing(self):
        ctx = context()
        load()["publish"](ctx, StepReport("publish"))
        self.assertNotIn("scripts/request-domains.sh", [c[0] for c, _ in ctx.runner.commands])

    def test_a_failed_request_fails_the_step(self):
        def extra(cmd):
            if cmd[2:4] == ["state", "list"]:
                return Result(0, "module.web\n")
            return Result(1, stderr="vm has no published_domains output") if cmd[0] == "scripts/request-domains.sh" else None

        ctx = context(lambda cmd: answer_outputs(cmd, extra))
        with self.assertRaisesRegex(StepFailed, "request-domains.sh failed for vm"):
            load()["publish"](ctx, StepReport("publish"))


class PrepTest(unittest.TestCase):
    def test_ssh_configuration_is_private(self):
        ctx = context(stacks={"planes": "stacks/shared/planes"})
        ctx.config["ssh_key"] = "~/.ssh/key"
        load()["prep"](ctx, StepReport("prep"))
        self.assertEqual(ctx.ssh_config.stat().st_mode & 0o777, 0o600)
        self.assertIn("User ops", ctx.ssh_config.read_text())
        self.assertNotIn("~", ctx.ssh_config.read_text())

    def test_cluster_credential_is_the_entry_renamed_openstack(self):
        try:
            import yaml
        except ImportError:
            self.skipTest("PyYAML (installed with the openstack client) is not available")
        ctx = context(stacks={"planes": "stacks/shared/planes", "published": "stacks/tenants/kubernetes"})
        clouds = ctx.work / "clouds.yaml"
        entry = {"auth": {"auth_url": "https://keystone.example:5000/v3"}, "cacert": "/local/ca.pem"}
        clouds.write_text(yaml.safe_dump({"clouds": {"my-cluster": entry}}))
        ctx.config.update(clouds_yaml=str(clouds), cluster_clouds={"published": "my-cluster"}, ssh_key="k")
        load()["prep"](ctx, StepReport("prep"))
        written = ctx.work / "published-clouds.yaml"
        self.assertEqual(written.stat().st_mode & 0o777, 0o600)
        credential = yaml.safe_load(written.read_text())["clouds"]["openstack"]
        self.assertEqual(credential["cacert"], "/opt/platform/cacert.pem")
        self.assertEqual(credential["auth"], entry["auth"])


if __name__ == "__main__":
    unittest.main()
