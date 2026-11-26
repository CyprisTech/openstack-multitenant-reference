"""The guide sections the steps name (@step(name, guide=...)) exist: a renamed heading or a moved
file fails here. Every step names its sections, or is listed below with the reason. No cloud."""

import re
import unittest
from pathlib import Path

from campaign.steps import GUIDES, load

ROOT = Path(__file__).resolve().parent.parent.parent.parent

# Steps that run no procedure of the documentation, with the reason.
UNDOCUMENTED = {}


def anchors(path):
    """The anchors of the headings of a Markdown file, as GitHub writes them; not in code blocks."""
    found, fence = set(), False
    for line in (ROOT / path).read_text().splitlines():
        if line.startswith("```"):
            fence = not fence
        heading = None if fence else re.match(r"^#{1,6} (.+)$", line)
        if heading:
            text = re.sub(r"[`*_]", "", heading.group(1).strip().lower())
            found.add(re.sub(r"[^a-z0-9 -]", "", text).replace(" ", "-"))
    return found


class GuidesTest(unittest.TestCase):
    def test_each_section_exists(self):
        for step, guides in GUIDES.items():
            for guide in guides:
                path, _, anchor = guide.partition("#")
                with self.subTest(step=step, guide=guide):
                    self.assertTrue((ROOT / path).exists(), f"no file {path}")
                    if anchor:
                        self.assertIn(anchor, anchors(path), f"no section #{anchor} in {path}")

    def test_every_step_names_its_sections(self):
        for step in load():
            with self.subTest(step=step):
                self.assertTrue(step in GUIDES or step in UNDOCUMENTED, f"step {step} names no guide section")


if __name__ == "__main__":
    unittest.main()
