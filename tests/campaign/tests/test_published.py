"""The published cluster family, the scenes and the teardown, against a fake cloud."""

import json
import unittest

from campaign.context import INPUTS, StepFailed
from campaign.report import StepReport
from campaign.steps import load
from campaign.tools import Result

from tests.test_foundation import context

STACKS = {
    "planes": "stacks/shared/planes",
    "entry-point": "stacks/shared/entry-point",
    "vm": "stacks/tenants/vm",
    "isolated": "stacks/tenants/isolated",
}
OUTPUTS = {
    "load_balancer": {"floating_ip": "192.0.2.80"},
    "service_address": "192.0.2.90:443",
    "bastion": "192.0.2.10",
    "instances": {"a": "10.21.0.11"},
    "transit": {},
}


def answer(ssh=0, curl_out="Hostname: web-1\n", apply_vm=0):
    def run(cmd):
        if cmd[0] == "tofu" and "output" in cmd:
            return Result(0, json.dumps(OUTPUTS[cmd[4]]))
        if cmd[0] == "tofu" and "apply" in cmd and "-chdir=stacks/tenants/vm" in cmd:
            return Result(apply_vm)
        if cmd[0] == "ssh":
            return Result(ssh)
        if cmd[0] == "curl":
            return Result(0, curl_out)
        return Result(0)

    return run


def with_inputs(ctx, key, values):
    (ctx.root / ctx.stack(key) / INPUTS).write_text(json.dumps(values))
    return ctx.root / ctx.stack(key) / INPUTS


class DirectTest(unittest.TestCase):
    def test_exposed_then_back_to_the_entry_point(self):
        ctx = context(answer(ssh=1), stacks=STACKS)
        path = with_inputs(ctx, "vm", {"exposure": "entry-point"})
        entry = StepReport("direct")
        load()["direct"](ctx, entry)
        applied = [c for c, _ in ctx.runner.commands if "apply" in c and "-chdir=stacks/tenants/vm" in c]
        self.assertEqual(len(applied), 2)
        self.assertEqual(json.loads(path.read_text()), {"exposure": "entry-point"})
        self.assertEqual(entry.measures["https site-a.example.org"], "12/12")
        self.assertFalse((ctx.work / "vm.inputs.bak").exists())

    def test_the_inputs_are_restored_when_the_exposed_service_fails(self):
        ctx = context(answer(ssh=1, curl_out="nothing here\n"), stacks=STACKS)
        path = with_inputs(ctx, "vm", {"exposure": "entry-point"})
        with self.assertRaisesRegex(StepFailed, "requests failed"):
            load()["direct"](ctx, StepReport("direct"))
        self.assertEqual(json.loads(path.read_text()), {"exposure": "entry-point"})

    def test_an_entry_point_that_still_reaches_the_instances_fails(self):
        ctx = context(answer(ssh=0), stacks=STACKS)
        with_inputs(ctx, "vm", {"exposure": "entry-point"})
        with self.assertRaisesRegex(StepFailed, "still reaches 10.21.0.11"):
            load()["direct"](ctx, StepReport("direct"))


class HostileTest(unittest.TestCase):
    def inputs(self):
        return {"plane_attachment": {"observability": {"routes": []}}}

    def test_closed_ports_pass_and_the_route_is_removed(self):
        ctx = context(answer(ssh=1), stacks=STACKS, options={"planes": {"attachments": {"web": {"cidr": "10.21.0.0/24"}}}})
        ctx.mode = "interface"
        ctx.config["hostile_next_hop"] = "172.31.1.1"
        path = with_inputs(ctx, "isolated", self.inputs())
        writes = []
        original = ctx.runner.run

        def run(cmd, **kwargs):
            if "apply" in cmd:
                writes.append(json.loads(path.read_text()))
            return original(cmd, **kwargs)

        ctx.runner.run = run
        # ssh 1 = closed for the ports, but also "cloud-init error" for the wait: answer per command.
        ctx.runner.answer = lambda cmd: Result(0) if cmd[0] == "ssh" and "cloud-init" in cmd[-1] else answer(ssh=1)(cmd)
        entry = StepReport("hostile")
        load()["hostile"](ctx, entry)
        routes = writes[0]["plane_attachment"]["observability"]["routes"]
        self.assertEqual(routes, [{"destination": "10.21.0.0/24", "next_hop": "172.31.1.1"}])
        self.assertEqual(writes[1], self.inputs())
        self.assertEqual(entry.measures["hostile"], "closed")

    def test_an_open_port_fails(self):
        ctx = context(answer(ssh=0), stacks=STACKS)
        ctx.mode = "interface"
        ctx.config["hostile_next_hop"] = "172.31.1.1"
        with_inputs(ctx, "isolated", self.inputs())
        with self.assertRaisesRegex(StepFailed, "opened 10.21.0.11"):
            load()["hostile"](ctx, StepReport("hostile"))

    def test_gateway_mode_skips(self):
        ctx = context(answer(), stacks=STACKS)
        load()["hostile"](ctx, StepReport("hostile"))
        self.assertFalse(ctx.runner.commands)


class TeardownTest(unittest.TestCase):
    def test_goes_on_after_a_failure_then_reports_it(self):
        def run(cmd):
            if "destroy" in cmd:
                return Result(1 if "-chdir=stacks/tenants/vm" in cmd else 0)
            return answer()(cmd)

        ctx = context(run, stacks=STACKS)
        (ctx.work / "published-once").touch()
        entry = StepReport("teardown")
        with self.assertRaisesRegex(StepFailed, "vm: destroy failed"):
            load()["teardown"](ctx, entry)
        destroyed = [c[1] for c, _ in ctx.runner.commands if "destroy" in c]
        self.assertEqual(destroyed, ["-chdir=stacks/tenants/isolated", "-chdir=stacks/tenants/vm",
                                     "-chdir=stacks/shared/entry-point", "-chdir=stacks/shared/planes"])  # fmt: skip
        self.assertFalse((ctx.work / "published-once").exists())
        self.assertEqual(entry.measures["destroyed"], "3/4")


if __name__ == "__main__":
    unittest.main()
