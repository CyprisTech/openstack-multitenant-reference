"""The rows of the isolation test, produced from the members of a deployment (lz check)."""

import re
import unittest
from pathlib import Path

from landing_zone.isolation import RULES, Member, matrix, rows


def scenario():
    """The members of the reference scenario, as the outputs of a campaign give them."""
    return [
        Member("entry-point", "entry-point", {"publication": "shared", "observability": "tenant"},
               instances={"t1-edge-1": "10.20.0.196"}, bastion="192.0.2.85", public_address="203.0.113.35"),
        Member("web", "tenant", {"publication": "tenant", "observability": "tenant", "internal": "tenant"},
               instances={"t1-web-1": "10.21.0.68"}, bastion="192.0.2.123", service_address="10.21.0.127",
               egress="router"),
        Member("private", "tenant", {"observability": "tenant", "internal": "tenant"},
               instances={"t1-private-1": "10.22.0.102"}, bastion="192.0.2.67", egress="none"),
        Member("shared", "service", {"internal": "shared", "observability": "tenant"},
               services={"ingress": ["192.0.2.52:443"], "echo": ["192.0.2.33:7000"]}, consumers=["web"]),
    ]  # fmt: skip


def key(r):
    return (r["source"]["label"], r["target"]["address"], r["port"], r["expected"])


class ScenarioTest(unittest.TestCase):
    """The rows of the campaign that the rules must produce (isolation-shared.txt, 2026-11-26)."""

    def test_the_generic_rows_of_the_campaign_are_produced(self):
        produced = {key(r) for r in rows(scenario(), receiver="10.34.0.8:9090")}
        expected = {
            ("test runner", "203.0.113.35", 443, "open"), ("test runner", "203.0.113.35", 80, "open"),
            ("test runner", "10.21.0.127", 443, "closed"),
            ("entry-point t1-edge-1", "10.21.0.127", 443, "open"),
            ("entry-point t1-edge-1", "10.21.0.68", 443, "closed"),
            ("private t1-private-1", "10.21.0.127", 443, "closed"),
            ("web t1-web-1", "10.20.0.196", 443, "closed"),
            ("entry-point t1-edge-1", "10.34.0.8", 9090, "open"), ("web t1-web-1", "10.34.0.8", 9090, "open"),
            ("private t1-private-1", "10.34.0.8", 9090, "open"),
            ("web t1-web-1", "10.22.0.102", 22, "closed"), ("private t1-private-1", "10.21.0.68", 443, "closed"),
            ("private t1-private-1", "1.1.1.1", 443, "closed"),
            ("web t1-web-1", "192.0.2.52", 443, "open"), ("web t1-web-1", "192.0.2.33", 7000, "open"),
            ("private t1-private-1", "192.0.2.52", 443, "closed"), ("entry-point t1-edge-1", "192.0.2.52", 443, "closed"),
        }  # fmt: skip
        self.assertEqual(expected - produced, set())

    def test_every_source_has_a_positive_control(self):
        listed = rows(scenario(), receiver="10.34.0.8:9090")
        for source in {r["source"]["label"] for r in listed}:
            results = {r["expected"] for r in listed if r["source"]["label"] == source}
            self.assertIn("open", results, f"{source} has closed rows only: they would prove nothing")


class DeploymentTest(unittest.TestCase):
    def test_a_consumer_reaches_its_service_and_nobody_else_does(self):
        members = [
            Member("shop", "tenant", {"internal": "tenant", "observability": "tenant"},
                   instances={"shop-1": "10.21.0.5"}, bastion="192.0.2.1"),
            Member("legacy", "tenant", {"internal": "tenant", "observability": "tenant"},
                   instances={"legacy-1": "10.25.0.5"}, bastion="192.0.2.2"),
            Member("registry", "service", {"internal": "shared", "observability": "tenant"},
                   instances={"registry-1": "10.37.0.5"}, bastion="192.0.2.3",
                   services={"registry": ["203.0.113.5:443"]}, consumers=["shop"]),
        ]  # fmt: skip
        produced = {key(r) for r in rows(members, receiver="198.51.100.9:443")}
        self.assertIn(("shop shop-1", "203.0.113.5", 443, "open"), produced)
        self.assertIn(("legacy legacy-1", "203.0.113.5", 443, "closed"), produced)
        self.assertIn(("shop shop-1", "10.37.0.5", 443, "closed"), produced)  # its instance: through the address only
        self.assertIn(("registry registry-1", "10.21.0.5", 22, "closed"), produced)

    def test_a_project_of_type_existing_without_access_is_a_target_only(self):
        members = [
            Member("shop", "tenant", {"internal": "tenant", "observability": "tenant"}, instances={"shop-1": "10.21.0.5"},
                   bastion="192.0.2.1"),
            Member("legacy", "tenant", {"internal": "tenant"}, instances={"legacy": "10.25.0.5"}),
        ]  # fmt: skip
        listed = rows(members, receiver="198.51.100.9:443")
        self.assertNotIn("legacy", {r["source"]["label"].split()[0] for r in listed})
        self.assertIn(("shop shop-1", "10.25.0.5", 22, "closed"), {key(r) for r in listed})


class UniqueTest(unittest.TestCase):
    def test_a_row_two_rules_expect_is_probed_once(self):
        listed = rows(scenario(), receiver="10.34.0.8:9090")
        keys = [(r["source"]["label"], r["target"]["address"], r["port"]) for r in listed]
        self.assertEqual(len(keys), len(set(keys)))

    def test_a_source_without_positive_control_is_a_target_only(self):
        members = scenario() + [
            Member("internal", "service", {"internal": "shared"}, instances={"t1-internal-1": "10.35.0.5"},
                   bastion="192.0.2.90", services={"internal": ["192.0.2.60:8080"]}, consumers=["published"]),
        ]  # fmt: skip
        listed = rows(members, receiver="10.34.0.8:9090")
        self.assertNotIn("internal t1-internal-1", {r["source"]["label"] for r in listed})
        self.assertIn(("web t1-web-1", "192.0.2.60", 8080, "closed"), {key(r) for r in listed})


class MatrixTest(unittest.TestCase):
    MATRIX = Path(__file__).resolve().parents[2] / "docs" / "reference" / "isolation-matrix.md"

    def test_the_matrix_shows_the_rules_as_they_are(self):
        found = re.search(r"<!-- BEGIN_RULES[^>]*-->\n(.*?)<!-- END_RULES -->", self.MATRIX.read_text(), re.S)
        self.assertIsNotNone(found, "the markers of the rules are in the isolation matrix")
        self.assertEqual(found.group(1).strip(), matrix().strip(),
                         "regenerate the table: python3 -c 'from landing_zone import isolation; print(isolation.matrix())'")

    def test_every_row_names_a_rule_of_the_table(self):
        listed = rows(scenario(), receiver="10.34.0.8:9090")
        self.assertEqual({r["rule"] for r in listed} - set(RULES), set())


class OwnRowsTest(unittest.TestCase):
    def test_the_adopters_rows_from_its_file(self):
        import tempfile  # noqa: PLC0415

        from landing_zone.commands import own_rows  # noqa: PLC0415

        base = Path(tempfile.mkdtemp())
        rows_file = '[[rows]]\nfrom = "web"\nto = "192.0.2.80"\nport = 5432\nexpected = "closed"\n'
        rows_file += '[[rows]]\nfrom = "local"\nto = "192.0.2.81"\nport = 443\nexpected = "open"\n'
        (base / "rows.toml").write_text(rows_file)
        listed = own_rows({"base": str(base), "check": {"rows": "rows.toml"}}, scenario())
        expected = [("web t1-web-1", "192.0.2.80", 5432, "closed"), ("test runner", "192.0.2.81", 443, "open")]
        self.assertEqual([key(r) for r in listed], expected)
        self.assertEqual({r["rule"] for r in listed}, {"own"})
