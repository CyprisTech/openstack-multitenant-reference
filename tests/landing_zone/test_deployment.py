"""lz deploy, without a cloud: the configuration of the example, its checks, the scenario it makes."""

import tempfile
import unittest
from pathlib import Path

from landing_zone import deployment

ROOT = Path(__file__).resolve().parents[2]
EXAMPLE = ROOT / "examples" / "deployment" / "landing-zone.toml"


class ExampleTest(unittest.TestCase):
    def test_the_example_is_a_valid_configuration(self):
        config = deployment.load(EXAMPLE)
        self.assertEqual([t["name"] for t in config["tenants"]], ["shop", "apps", "legacy"])
        self.assertEqual(deployment.provided(config)["receiver"], "https://10.34.0.5:9090/api/v1/write")

    def test_the_scenario_of_the_example(self):
        scenario = deployment.scenario(deployment.load(EXAMPLE))
        self.assertEqual(scenario.stacks["shop"], "stacks/tenants/vm")
        self.assertEqual(scenario.states, {"shop": "shop", "apps": "apps"})
        self.assertNotIn("egress", scenario.stacks)  # no clouds.egress in the example
        self.assertNotIn("legacy", scenario.stacks)  # existing: attached, nothing deployed
        self.assertTrue(scenario.options["planes"]["attachments"]["legacy"]["existing"])
        self.assertEqual(scenario.options["planes"]["attachments"]["metrics"]["planes"], {"observability": "shared"})
        attachments = scenario.options["planes"]["attachments"]
        self.assertEqual(attachments["edge"]["planes"], {"publication": "shared", "observability": "tenant"})
        self.assertEqual(attachments["apps"]["cidr"], "10.24.0.0/22")
        self.assertEqual(scenario.options["planes"]["tenant_ranges"]["publication"], ["10.21.0.0/24", "10.24.0.0/22"])
        self.assertIn("10.25.0.0/24", scenario.options["planes"]["tenant_ranges"]["internal"])
        self.assertEqual(scenario.options["clusters"], ["apps"])
        self.assertEqual(scenario.sequences["deploy"],
                         ["prep", "planes", "deploy-entry-point", "tenant-shop", "tenant-apps", "transit",
                          "deploy-publish", "cluster-apps"])  # fmt: skip


class ChecksTest(unittest.TestCase):
    def problems(self, text):
        with tempfile.TemporaryDirectory() as base:
            path = Path(base) / "landing-zone.toml"
            path.write_text(text)
            with self.assertRaises(deployment.ConfigError) as caught:
                deployment.load(path)
        return "\n".join(caught.exception.problems)

    def test_each_problem_says_what_to_fix(self):
        found = self.problems('profile = "x"\n[[tenants]]\nname = "planes"\ntype = "vm"\ncidr = "10.0.0.0/33"\n')
        self.assertIn("profile: one of private-cloud, public-cloud", found)
        self.assertIn("external.receiver", found)
        self.assertIn("tenants[0] (planes).name", found)  # a reserved name
        self.assertIn("tenants[0] (planes).cidr", found)

    def test_an_existing_project_takes_no_inputs(self):
        found = self.problems('[[tenants]]\nname = "old"\ntype = "existing"\nvalues = { a = 1 }\n')
        self.assertIn("tenants[0] (old): an existing project takes no inputs", found)

    def test_a_shared_service_names_tenants_as_consumers(self):
        found = self.problems('[[tenants]]\nname = "shop"\n[[shared-services]]\nname = "platform"\ntype = "kubernetes"\n'
                              'consumers = ["nobody"]\nprovides = { colour = "blue" }\n')
        self.assertIn("shared-services[0] (platform).consumers: nobody is not a tenant", found)
        self.assertIn("shared-services[0] (platform).provides", found)
        self.assertIn("shared-services[0] (platform).cluster_cloud", found)

    def test_a_kubernetes_tenant_needs_its_cluster_credential(self):
        found = self.problems('[[tenants]]\nname = "apps"\ntype = "kubernetes"\n')
        self.assertIn("tenants[0] (apps).cluster_cloud", found)

    def test_a_backend_key_names_the_stack(self):
        found = self.problems('[state]\nbackend = "s3"\nkey = "key=states.tfstate"\n')
        self.assertIn("state.key", found)


class BackendTest(unittest.TestCase):
    def test_one_key_per_stack(self):
        config = {"state": {"backend": "s3", "config": {"bucket": "b"}, "key": "key=par1/{stack}.tfstate"}}
        self.assertEqual(deployment.backend(config, "shop"),
                         {"type": "s3", "config": {"bucket": "b"}, "key": "key=par1/shop.tfstate"})  # fmt: skip
        self.assertIsNone(deployment.backend({}, "shop"))


if __name__ == "__main__":
    unittest.main()
