"""What a recorded step shows: the output of the tools, not only the commands."""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from campaign.tools import Runner  # noqa: E402


class VerboseTest(unittest.TestCase):
    def run_echo(self, verbose, quiet=False):
        lines = []
        Runner(echo=lines.append, verbose=verbose).run(["sh", "-c", "echo out; echo err >&2"], quiet=quiet)
        return lines

    def test_verbose_prints_the_output(self):
        self.assertEqual(self.run_echo(True), ["$ sh -c 'echo out; echo err >&2'", "out", "err"])

    def test_not_verbose_prints_the_command_only(self):
        self.assertEqual(self.run_echo(False), ["$ sh -c 'echo out; echo err >&2'"])

    def test_quiet_commands_stay_quiet(self):
        self.assertEqual(self.run_echo(True, quiet=True), [])


if __name__ == "__main__":
    unittest.main()
