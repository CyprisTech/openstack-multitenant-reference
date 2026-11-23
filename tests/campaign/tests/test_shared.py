"""The shared cluster steps, against a fake cloud and a fake cluster."""

import base64
import json
import unittest

from campaign.context import StepFailed
from campaign.kube import delete_cluster
from campaign.report import StepReport
from campaign.steps import load
from campaign.steps.shared import wait_for_revocation
from campaign.tools import Result

from tests.test_foundation import context

SECRET = "s3cr3t-never-printed"
STACKS = {"shared": "stacks/shared/kubernetes", "vm": "stacks/tenants/vm"}


class RevocationTest(unittest.TestCase):
    def test_waits_until_the_old_credential_fails(self):
        answers = iter([0, 0, 1])
        ctx = context(lambda cmd: Result(next(answers)) if "token" in cmd else Result(0), stacks=STACKS)
        told = []
        ctx.notify = told.append
        wait_for_revocation(ctx, "old-credential")
        self.assertIn("old-credential", told[0])

    def test_gives_up_after_the_attempts(self):
        ctx = context(lambda cmd: Result(0), stacks=STACKS)
        ctx.notify = lambda message: None
        with self.assertRaisesRegex(StepFailed, "still valid"):
            wait_for_revocation(ctx, "old-credential", attempts=3)


class DeleteClusterTest(unittest.TestCase):
    def test_nothing_to_do_without_a_bootstrap_instance(self):
        ctx = context(lambda cmd: Result(0, "null") if "output" in cmd else Result(0), stacks=STACKS)
        delete_cluster(ctx, "shared", ctx.work / "shared.kubeconfig")
        self.assertFalse([c for c, _ in ctx.runner.commands if c[0] == "ssh"])


class RotateTest(unittest.TestCase):
    def test_the_new_secret_goes_through_standard_input_only(self):
        try:
            import yaml
        except ImportError:
            self.skipTest("PyYAML (installed with the openstack client) is not available")
        conf = "[Global]\napplication-credential-id=old\napplication-credential-secret=old-secret\n"
        inputs = []

        def answer(cmd):
            if cmd[0] == "tofu" and "output" in cmd:
                return Result(0, json.dumps("192.0.2.30"))
            if "secret" in cmd and "cloud-config" in cmd and "jsonpath" in cmd[-1]:
                return Result(0, base64.b64encode(conf.encode()).decode())
            if "secret" in cmd and "-o" in cmd and cmd[-1] == "json":
                return Result(0, json.dumps({"apiVersion": "v1", "kind": "Secret", "metadata": {"name": "x"}, "data": {}}))
            if "deployment,daemonset" in cmd:
                return Result(0, "deployment.apps/openstack-cloud-controller-manager\ndaemonset.apps/csi-cinder-nodeplugin\n")
            if "pod" in cmd and "jsonpath={.spec.nodeName}" in cmd:
                answer.nodes = getattr(answer, "nodes", iter(["n1", "n2"]))
                return Result(0, next(answer.nodes))
            if "sha256sum" in cmd:
                return Result(0, "abc  /data/marker")
            if "token" in cmd:
                return Result(1)
            return Result(0)

        ctx = context(answer, stacks=STACKS)
        printed = []
        ctx.runner.echo = printed.append
        ctx.notify = printed.append
        original = ctx.runner.run

        def run(cmd, **kwargs):
            if kwargs.get("input"):
                inputs.append(kwargs["input"])
            return original(cmd, **kwargs)

        ctx.runner.run = run
        clouds = ctx.work / "clouds.yaml"
        clouds.write_text(yaml.safe_dump({"clouds": {"next": {"auth": {
            "application_credential_id": "new-id", "application_credential_secret": SECRET}}}}))  # fmt: skip
        ctx.config.update(clouds_yaml=str(clouds), cluster_clouds={"shared": "old", "shared_next": "next"})
        (ctx.work / "volume.sha256").write_text("abc\n")
        load()["rotate"](ctx, StepReport("rotate"))

        argv = " ".join(" ".join(c) for c, _ in ctx.runner.commands)
        self.assertNotIn(SECRET, argv)
        self.assertNotIn(SECRET, "\n".join(printed))
        conf_secret = [i for i in inputs if "cloud.conf" in i][0]
        written = base64.b64decode(json.loads(conf_secret)["data"]["cloud.conf"]).decode()
        self.assertIn(f"application-credential-secret={SECRET}", written)
        self.assertIn("application-credential-id=new-id", written)
        restarted = [c for c, _ in ctx.runner.commands if "restart" in c]
        self.assertEqual(len(restarted), 2)


class UpgradeTest(unittest.TestCase):
    def test_done_when_every_machine_is_a_ready_node_of_the_new_version(self):
        rounds = iter([
            "cp-1 Ready control-plane 1d v1.35.10\nw-1 Ready <none> 1d v1.35.10\n",
            "cp-2 Ready control-plane 1m v1.36.5\nw-1 Ready <none> 1d v1.35.10\n",
            "cp-2 Ready control-plane 5m v1.36.5\nw-2 Ready <none> 1m v1.36.5\n",
        ])  # fmt: skip

        def answer(cmd):
            if cmd[0] == "tofu" and "output" in cmd:
                name = cmd[4]
                values = {"services": {"ingress": "10.36.0.50:443"}, "bastion": "192.0.2.10", "instances": {"a": "10.21.0.11"}}
                return Result(0, json.dumps(values[name]))
            if "nodes" in cmd and "--no-headers" in cmd:
                return Result(0, next(rounds))
            if "machines" in cmd:
                return Result(0, "m1\nm2\n")
            if "config" in cmd:
                return Result(0, "https://10.36.0.10:6443")
            if "traefik-internal" in cmd:
                return Result(0, "10.36.0.50")
            if "dig" in cmd[-1]:
                return Result(0, "10.36.0.50\n")
            if cmd[0] == "ssh":
                return Result(0, "Hostname: whoami-1\n")
            if "jsonpath={.spec.nodeName}" in cmd:
                answer.nodes = getattr(answer, "nodes", iter(["n1", "n2"]))
                return Result(0, next(answer.nodes))
            if "sha256sum" in cmd:
                return Result(0, "abc  /data/marker")
            return Result(0)

        ctx = context(answer, stacks=dict(STACKS, receiver="tests/fixtures/receiver"))
        ctx.config.update(upgrade={"version": "v1.36.5", "image": "ubuntu-2404-kube-v1.36.5"},
                          name_server="192.0.2.53", ssh_key="k")
        (ctx.work / "volume.sha256").write_text("abc\n")
        entry = StepReport("upgrade")
        load()["upgrade"](ctx, entry)
        patch = [c for c, _ in ctx.runner.commands if "patch" in c][0]
        self.assertIn("ubuntu-2404-kube-v1-36-5", patch[-1])
        self.assertEqual(entry.measures["https shared"], "6/6")
        self.assertEqual(entry.measures["volume after the upgrade"], "intact")


if __name__ == "__main__":
    unittest.main()
