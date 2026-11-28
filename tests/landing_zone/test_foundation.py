"""The foundation steps and the helpers they use, against a fake cloud."""

import json
import tempfile
import unittest
from pathlib import Path

from landing_zone import deployment, retry
from landing_zone.context import INPUTS, Context, StepFailed
from landing_zone.report import StepReport
from landing_zone.scenario import Scenario
from landing_zone.steps import load
from landing_zone.tools import Result, Runner

STACKS = {
    "planes": "stacks/shared/planes",
    "receiver": "tests/fixtures/receiver",
    "entry-point": "stacks/shared/entry-point",
    "web": "stacks/tenants/vm",
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
        self.inputs = []  # what each command received on its standard input

    def run(self, cmd, cwd=None, env=None, check=True, quiet=False, input=None, timeout=None, stream=False):
        cmd = [str(c) for c in cmd]
        self.commands.append((cmd, env))
        if input:
            self.inputs.append(input)
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


def context(answer=answer_outputs, stacks=STACKS, options=None, config=None, states=None):
    root = Path(tempfile.mkdtemp())
    for path in stacks.values():
        (root / path).mkdir(parents=True, exist_ok=True)
    scenario = Scenario("t", "private-cloud", ["gateway"], stacks, {}, options or {}, states or {})
    config = config or {"clouds": {"planes": "hub", "receiver": "shared", "entry-point": "edge", "web": "web"},
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
                "web": {"stack": "web", "cidr": "10.21.0.0/24", "planes": {"publication": "tenant"}},
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


WEB = {"name": "web", "type": "vm", "cidr": "10.21.0.0/24", "planes": {"publication": "tenant"},
       "values": {"exposure": "entry-point", "egress": "router"}}  # fmt: skip


def register(*tenants):
    """The steps of these tenants (tenant-<name>, deploy-egress-tenants), as lz deploy registers them."""
    deployment.register({"tenants": list(tenants), "shared-services": []})
    return load()


class TenantInputsTest(unittest.TestCase):
    def test_web_gets_the_outputs_of_the_others_and_waits_for_each_instance(self):
        ctx = context()
        register(WEB)["tenant-web"](ctx, StepReport("tenant-web"))
        written = inputs(ctx, "web")
        self.assertEqual(written["exposure"], "entry-point")
        self.assertEqual(written["web_cidr"], "10.21.0.0/24")
        self.assertEqual(written["monitoring"], {"receiver": OUTPUTS[("tests/fixtures/receiver", "receiver_url")]})
        self.assertEqual(written["edge_sources"], ["10.20.0.0/24"])
        self.assertEqual(written["plane_attachment"], {"publication": {"routes": []}})
        # Without the test ACME authority, no certificates input: demonstration certificates.
        self.assertNotIn("certificates", written)
        ssh = [c for c, _ in ctx.runner.commands if c[0] == "ssh"]
        self.assertEqual([c[-2] for c in ssh], ["ops@10.21.0.11", "ops@10.21.0.12"])
        self.assertIn("ops@192.0.2.10", ssh[0])


class ResolverTest(unittest.TestCase):
    def outputs(self, cmd):
        values = {
            ("tests/fixtures/resolver", "resolver"): "203.0.113.53",
            ("tests/fixtures/resolver", "bastion"): "192.0.2.20",
            ("tests/fixtures/resolver", "address"): "10.38.0.5",
            ("stacks/shared/planes", "attachments"): {
                "resolver": {"planes": {"internal": {"routes": []}}},
                "private": {"planes": {"observability": {"routes": []}, "internal": {"routes": []}}},
            },
            ("stacks/tenants/vm", "instances"): {"private-1": "10.22.0.11"},
        }
        if cmd[0] == "tofu" and cmd[2] == "output":
            key = (cmd[1].removeprefix("-chdir="), cmd[4])
            if key in values:
                return Result(0, json.dumps(values[key]))
        return None

    def test_the_resolver_forwards_the_test_zone_and_the_private_tenant_uses_it(self):
        stacks = dict(STACKS, resolver="tests/fixtures/resolver", private="stacks/tenants/vm")
        config = {"clouds": {"planes": "hub", "receiver": "shared", "resolver": "shared", "entry-point": "edge",
                             "web": "web", "private": "private"},
                  "site": "t1", "ssh_user": "ops", "test_zone": "example.org", "name_server": "192.0.2.53"}  # fmt: skip
        ctx = context(answer=lambda cmd: answer_outputs(cmd, self.outputs), stacks=stacks, config=config,
                      states={"web": "web", "private": "private"})  # fmt: skip
        load()["resolver"](ctx, StepReport("resolver"))
        self.assertEqual(inputs(ctx, "resolver")["forward_zones"], {"example.org": ["192.0.2.53"]})
        private = {"name": "private", "type": "vm", "cidr": "10.22.0.0/24", "planes": {"internal": "tenant"},
                   "values": {"exposure": "none", "egress": "none"}, "resolver": True}  # fmt: skip
        register(WEB, private)["tenant-private"](ctx, StepReport("tenant-private"))
        written = json.loads((ctx.root / "stacks/tenants/vm/mode.private.tfvars.json").read_text())
        self.assertEqual(written["dns_nameservers"], ["203.0.113.53"])
        self.assertEqual(written["egress"], "none")
        self.assertNotIn("edge_sources", written)


class SharedEgressTest(unittest.TestCase):
    def outputs(self, cmd):
        values = {
            ("stacks/shared/egress", "proxy"): "http://203.0.113.39:3128",
            ("stacks/shared/egress", "bastion"): "192.0.2.30",
            ("stacks/shared/egress", "instances"): {"t1-egress-1": "10.39.0.11", "t1-egress-2": "10.39.0.12"},
            ("stacks/tenants/vm", "internal_sources"): ["203.0.113.23/32"],
            ("stacks/shared/planes", "attachments"): {
                "egress": {"planes": {"internal": {"routes": []}}},
                "egress-shared": {"planes": {"observability": {"routes": []}, "internal": {"routes": []}}},
            },
        }
        if cmd[0] == "tofu" and cmd[2] == "output":
            key = (cmd[1].removeprefix("-chdir="), cmd[4])
            if key in values:
                return Result(0, json.dumps(values[key]))
        return None

    def test_the_tenant_is_applied_then_declared_on_the_shared_egress(self):
        stacks = dict(STACKS, egress="stacks/shared/egress", **{"egress-shared": "stacks/tenants/vm"})
        config = {"clouds": {"planes": "hub", "receiver": "shared", "egress": "egress", "entry-point": "edge",
                             "web": "web", "egress-shared": "builds"}, "site": "t1", "ssh_user": "ops"}  # fmt: skip
        ctx = context(answer=lambda cmd: answer_outputs(cmd, self.outputs), stacks=stacks, config=config,
                      states={"web": "web", "egress-shared": "egress-shared"})  # fmt: skip
        tenant = {"name": "egress-shared", "type": "vm", "cidr": "10.23.0.0/24", "planes": {"internal": "tenant"},
                  "values": {"exposure": "none", "egress": "shared"}, "egress_proxy": True,
                  "egress_domains": [".archive.ubuntu.com"]}  # fmt: skip
        steps = register(WEB, tenant)
        steps["deploy-egress"](ctx, StepReport("deploy-egress"))
        self.assertEqual(inputs(ctx, "egress")["tenants"], {})
        steps["tenant-egress-shared"](ctx, StepReport("tenant-egress-shared"))
        written = json.loads((ctx.root / "stacks/tenants/vm/mode.egress-shared.tfvars.json").read_text())
        self.assertEqual(written["egress"], "shared")
        self.assertEqual(written["shared_egress"], {"proxy": "http://203.0.113.39:3128"})
        self.assertIsNone(written["egress_network"])
        steps["deploy-egress-tenants"](ctx, StepReport("deploy-egress-tenants"))
        declared = inputs(ctx, "egress")["tenants"]["egress-shared"]
        self.assertEqual(declared, {"sources": ["203.0.113.23/32"], "domains": [".archive.ubuntu.com"]})
        applies = [c for c, _ in ctx.runner.commands if "apply" in c]
        self.assertEqual([c[1] for c in applies][-2:], ["-chdir=stacks/tenants/vm", "-chdir=stacks/shared/egress"])


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
        ctx.apply("web")
        self.assertEqual(len(applies), 2)
        self.assertEqual(applies[1][-1], "-replace=x.y")

    def test_the_repair_hook_gets_the_inputs_file_and_the_state_of_a_member(self):
        def extra(cmd):
            if "apply" in cmd:
                return Result(1)
            return None

        ctx = context(lambda cmd: answer_outputs(cmd, extra), states={"web": "web"})
        ctx.config.update(repair_hook="/repair", repairs=1)
        with self.assertRaises(StepFailed):
            ctx.apply("web")
        cmd, env = next((c, e) for c, e in ctx.runner.commands if c[0] == "/repair")
        self.assertEqual(cmd[1:], ["stacks/tenants/vm", "mode.web.tfvars.json"])
        self.assertEqual(env["TF_DATA_DIR"], ".terraform/tenant-web")

    def test_a_plan_with_changes_after_apply_fails(self):
        ctx = context(lambda cmd: answer_outputs(cmd, lambda c: Result(2) if "plan" in c else None))
        with self.assertRaisesRegex(StepFailed, "plan not empty after apply: web"):
            ctx.apply("web")

    def test_a_failed_apply_without_a_hook_fails(self):
        ctx = context(lambda cmd: answer_outputs(cmd, lambda c: Result(1) if "apply" in c else None))
        with self.assertRaisesRegex(StepFailed, "apply failed: web"):
            ctx.apply("web")


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


class TenantStateTest(unittest.TestCase):
    """Two tenants of one stack directory: a state, a data directory and an inputs file each."""

    def test_a_tenant_has_its_state_and_its_inputs(self):
        stacks = dict(STACKS, private="stacks/tenants/vm")
        ctx = context(stacks=stacks, states={"web": "web", "private": "private"})
        (ctx.root / "stacks/tenants/vm" / INPUTS).write_text("{}")  # left by an earlier layout
        ctx.set_inputs("private", name="private")
        self.assertTrue((ctx.root / "stacks/tenants/vm/mode.private.tfvars.json").exists())
        self.assertFalse((ctx.root / "stacks/tenants/vm" / INPUTS).exists())
        ctx.apply("private")
        apply, env = next((c, e) for c, e in ctx.runner.commands if "apply" in c)
        self.assertIn("-var-file=mode.private.tfvars.json", apply)
        init = next(c for c, _ in ctx.runner.commands if "init" in c)
        self.assertIn("-backend-config=path=private.tfstate", init)
        self.assertEqual(ctx.stack("private").env()["TF_DATA_DIR"], ".terraform/tenant-private")


class PublishTest(unittest.TestCase):
    def test_first_publication_without_load_in_the_entry_point_project(self):
        ctx = context()
        entry = StepReport("publish")
        load()["publish"](ctx, entry)
        script = [(c, env) for c, env in ctx.runner.commands if c[0] == "scripts/publish-domains.sh"]
        self.assertEqual(script[0][0], ["scripts/publish-domains.sh", "--tool", "tofu"])
        self.assertEqual(script[0][1]["OS_CLOUD"], "edge")
        self.assertNotIn("publication load", entry.measures)
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
        with self.assertRaisesRegex(StepFailed, "request-domains.sh failed for web"):
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


class SharedServiceTest(unittest.TestCase):
    def outputs(self, cmd):
        values = {
            ("stacks/shared/planes", "attachments"): {
                "web": {"planes": {"internal": {"routes": []}}},
                "registry": {"planes": {"internal": {"routes": []}, "observability": {"routes": []}}},
            },
            ("stacks/tenants/vm", "internal_sources"): ["10.21.0.0/24"],
            ("stacks/shared/vm", "instances"): {"t1-registry-1": "10.37.0.11"},
            ("stacks/shared/vm", "bastion"): "192.0.2.40",
        }
        if cmd[0] == "tofu" and cmd[2] == "output":
            key = (cmd[1].removeprefix("-chdir="), cmd[4])
            if key in values:
                return Result(0, json.dumps(values[key]))
        if "state" in cmd and "list" in cmd:  # the consumer is deployed when its state is
            return Result(0, "module.web.x\n" if self.deployed else "")
        return None

    deployed = True

    def run_step(self):
        stacks = dict(STACKS, registry="stacks/shared/vm")
        config = {"clouds": {"planes": "hub", "receiver": "shared", "entry-point": "edge", "web": "web",
                             "registry": "registry"}, "site": "t1", "ssh_user": "ops"}  # fmt: skip
        ctx = context(answer=lambda cmd: answer_outputs(cmd, self.outputs), stacks=stacks, config=config,
                      states={"web": "web", "registry": "registry"})  # fmt: skip
        service = {"name": "registry", "type": "vm", "cidr": "10.37.0.0/27", "consumers": ["web"],
                   "planes": {"internal": "shared"}, "values": {"egress": "router"}}  # fmt: skip
        deployment.register({"tenants": [WEB], "shared-services": [service]})
        load()["service-registry"](ctx, StepReport("service-registry"))
        return ctx, json.loads((ctx.root / "stacks/shared/vm/mode.registry.tfvars.json").read_text())

    def test_a_consumer_not_deployed_yet_is_not_admitted(self):
        self.deployed = False
        _, written = self.run_step()
        self.assertEqual(written["consumers"], [])  # admitted when the step runs again

    def test_a_shared_service_on_virtual_machines_admits_its_consumers(self):
        ctx, written = self.run_step()
        self.assertEqual(written["consumers"], ["10.21.0.0/24"])
        self.assertEqual((written["name"], written["cidr"], written["egress"]), ("registry", "10.37.0.0/27", "router"))
        self.assertNotIn("bootstrap", written)  # no cluster
        ssh = [c for c, _ in ctx.runner.commands if c[0] == "ssh"]
        self.assertEqual([c[-2] for c in ssh], ["ops@10.37.0.11"])  # its instances, through its bastion
        self.assertIn("ops@192.0.2.40", ssh[0])


class EdgeTest(unittest.TestCase):
    @staticmethod
    def outputs(cmd):
        values = {
            ("stacks/shared/planes", "attachments"): {"edge": {"planes": {"publication": {"routes": []}}}},
            ("stacks/shared/entry-point", "instances"): {"t1-edge-1": "10.20.0.11"},
            ("stacks/shared/entry-point", "bastion"): "192.0.2.50",
        }
        if cmd[0] == "tofu" and cmd[2] == "output" and (cmd[1].removeprefix("-chdir="), cmd[4]) in values:
            return Result(0, json.dumps(values[(cmd[1].removeprefix("-chdir="), cmd[4])]))
        return None

    def test_a_run_started_again_keeps_the_published_domains(self):
        ctx = context(answer=lambda cmd: answer_outputs(cmd, self.outputs))
        domains = ctx.root / "stacks/shared/entry-point/domains.auto.tfvars.json"
        domains.write_text("{}")
        ctx.work.mkdir(parents=True, exist_ok=True)
        (ctx.work / "published-once").touch()
        load()["edge"](ctx, StepReport("edge"))
        self.assertTrue(domains.exists())  # served: the step does not withdraw them

    def test_the_first_run_starts_with_no_domain(self):
        ctx = context(answer=lambda cmd: answer_outputs(cmd, self.outputs))
        domains = ctx.root / "stacks/shared/entry-point/domains.auto.tfvars.json"
        domains.write_text("{}")
        load()["edge"](ctx, StepReport("edge"))
        self.assertFalse(domains.exists())
