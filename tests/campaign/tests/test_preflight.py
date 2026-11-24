"""The preflight: which credentials it checks, and what stops a run, without a cloud."""

import unittest

from campaign import preflight
from campaign.context import StepFailed
from campaign.tools import Result

from tests.test_core import context

STACKS = {"planes": "stacks/shared/planes", "shared": "stacks/shared/kubernetes"}
CONFIG = {
    "clouds": {"planes": "hub", "shared": "k8s-shared"},
    "cluster_clouds": {"shared": "cluster-1", "shared_next": "cluster-2", "published": "published-1"},
}


def refusing(*entries, projects=None):
    """A fake openstack client: `token issue` fails for the given clouds.yaml entries; the others
    open their own project, or the one `projects` gives them."""

    def fake(cmd):
        cloud = cmd[cmd.index("--os-cloud") + 1]
        if cloud in entries:
            return Result(1, "", "The request you have made requires authentication.")
        return Result(0, (projects or {}).get(cloud, f"project-of-{cloud}"))

    return fake


class PreflightTest(unittest.TestCase):
    def test_entries_of_the_stacks_and_the_clusters_of_the_scenario(self):
        ctx = context(stacks=STACKS, config=CONFIG)
        # The published cluster is not in the scenario; the next credential only with the rotation.
        self.assertEqual(preflight.credentials(ctx, ["planes", "cluster-shared"]), ["cluster-1", "hub", "k8s-shared"])
        self.assertIn("cluster-2", preflight.credentials(ctx, ["rotate"]))

    def test_a_refused_credential_stops_the_run(self):
        ctx = context(stacks=STACKS, config=CONFIG, fake=refusing("cluster-1"))
        with self.assertRaisesRegex(StepFailed, "cluster-1 does not authenticate"):
            preflight.check(ctx, ["cluster-shared"])

    def test_the_rotation_needs_a_new_credential(self):
        config = dict(CONFIG, cluster_clouds=dict(CONFIG["cluster_clouds"], shared_next="cluster-1"))
        ctx = context(stacks=STACKS, config=config)
        self.assertIn("shared_next is the current credential", " ".join(preflight.problems(ctx, ["rotate"])))

    def test_all_good(self):
        ctx = context(stacks=STACKS, config=CONFIG)
        self.assertEqual(preflight.problems(ctx, ["planes", "rotate"]), [])

    def test_two_stacks_in_one_project_stop_the_run(self):
        ctx = context(stacks=STACKS, config=CONFIG, fake=refusing(projects={"hub": "p1", "k8s-shared": "p1"}))
        with self.assertRaisesRegex(StepFailed, "hub, k8s-shared open the same project p1"):
            preflight.check(ctx, ["planes"])


if __name__ == "__main__":
    unittest.main()
