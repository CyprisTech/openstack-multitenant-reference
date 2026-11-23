"""What a recorded step shows: the output of the tools, not only the commands."""

import unittest

from campaign.tools import Runner


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
