"""Scenarios: loading, checks and the expansion of sequences."""

import tempfile
import unittest
from pathlib import Path

from landing_zone import scenario

SCENARIOS = Path(__file__).resolve().parents[2] / "tools" / "landing-zone" / "scenarios"


def write(text):
    f = tempfile.NamedTemporaryFile("w", suffix=".toml", delete=False)
    f.write(text)
    f.close()
    return f.name


class ScenarioTest(unittest.TestCase):
    def test_every_scenario_loads_and_expands(self):
        for path in sorted(SCENARIOS.glob("*.toml")):
            with self.subTest(path.name):
                s = scenario.load(path)
                self.assertEqual(s.profile, path.stem)
                steps = s.expand(["full"])
                self.assertEqual(steps[-3:], ["plans", "teardown", "leftovers"])
                self.assertNotIn("full", steps)

    def test_public_cloud_runs_no_kubernetes(self):
        s = scenario.load(SCENARIOS / "public-cloud.toml")
        self.assertEqual(s.modes, ["interface"])
        self.assertNotIn("published", s.stacks)
        self.assertNotIn("shared", s.stacks)
        self.assertFalse({"cluster", "direct-k8s", "rotate", "upgrade"} & set(s.expand(["full"])))

    def test_nested_sequences_keep_their_order(self):
        s = scenario.Scenario("t", "p", ["gateway"], {}, {"a": ["x", "b"], "b": ["y", "z"]})
        self.assertEqual(s.expand(["a", "w"]), ["x", "y", "z", "w"])

    def test_a_cycle_is_refused(self):
        s = scenario.Scenario("t", "p", ["gateway"], {}, {"a": ["b"], "b": ["a"]})
        with self.assertRaises(scenario.ScenarioError):
            s.expand(["a"])

    def test_unknown_mode_is_refused(self):
        path = write('profile = "p"\nmodes = ["bgp"]\n[stacks]\n[sequences]\n')
        with self.assertRaises(scenario.ScenarioError):
            scenario.load(path)

    def test_missing_key_is_refused(self):
        path = write('profile = "p"\nmodes = ["gateway"]\n[stacks]\n')
        with self.assertRaises(scenario.ScenarioError):
            scenario.load(path)


if __name__ == "__main__":
    unittest.main()
