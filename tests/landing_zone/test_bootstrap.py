"""The wait for a bootstrap instance, without a cloud."""

import unittest

from test_core import context

from landing_zone import kube
from landing_zone.context import StepFailed
from landing_zone.tools import Result

STACKS = {"published": "stacks/tenants/kubernetes"}
REFUSED = Result(255, "", "ssh: connect to host 192.0.2.10 port 22: Connection refused")


def instance(*answers):
    """A fake runner: the stack output, then the given SSH results in turn."""
    results = iter(answers)
    return lambda cmd: Result(0, '"192.0.2.10"') if "output" in cmd else next(results)


class BootstrapTest(unittest.TestCase):
    def test_ssh_refused_while_booting_is_retried(self):
        answers = [REFUSED, REFUSED, Result(0, "status: done")]
        ctx = context(stacks=STACKS, fake=instance(*answers))
        kube.wait_for_bootstrap(ctx, "published")
        ssh = [cmd for cmd, _ in ctx.runner.commands if cmd[0] == "ssh"]
        self.assertEqual(len(ssh), 3)

    def test_cloud_init_error_is_not_retried(self):
        ctx = context(stacks=STACKS, fake=instance(Result(1, "status: error")))
        with self.assertRaisesRegex(StepFailed, "not ready: status: error"):
            kube.wait_for_bootstrap(ctx, "published")


if __name__ == "__main__":
    unittest.main()
