__copyright__ = "Copyright © 2026 王孝慈. All rights reserved."

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

PROJECT = Path(__file__).resolve().parents[1]
STAPLER = PROJECT / "scripts/stapler_with_retry.sh"
NETWORK_LOST = 'Error Domain=NSURLErrorDomain Code=-1005 "The network connection was lost."'
TIMEOUT = 'Error Domain=NSURLErrorDomain Code=-1001 "The request timed out."'


class StaplerRetryTests(unittest.TestCase):
    def run_stapler(self, responses, operation="staple", arguments=None):
        with tempfile.TemporaryDirectory(prefix="mirage-notarization-") as temporary:
            root = Path(temporary)
            tools = root / "bin"
            tools.mkdir()
            (root / "responses.json").write_text(json.dumps(responses))
            xcrun = tools / "xcrun"
            xcrun.write_text(f"#!{sys.executable}\n" + '''import json
import os
from pathlib import Path
import sys

root = Path(os.environ["TEST_STAPLER_ROOT"])
calls = root / "calls.jsonl"
previous = calls.read_text().splitlines() if calls.exists() else []
with calls.open("a") as output:
    output.write(json.dumps(sys.argv[1:]) + "\\n")
responses = json.loads((root / "responses.json").read_text())
status, message = responses[min(len(previous), len(responses) - 1)]
print(message, file=sys.stderr if status else sys.stdout)
sys.exit(status)
''')
            xcrun.chmod(0o755)
            sleep = tools / "sleep"
            sleep.write_text('#!/bin/bash\nprintf "%s\\n" "$1" >> "$TEST_STAPLER_ROOT/sleeps.txt"\n')
            sleep.chmod(0o755)
            target = str(root / "App with spaces.app")
            environment = dict(os.environ, TEST_STAPLER_ROOT=str(root),
                               PATH=str(tools) + os.pathsep + os.environ.get("PATH", ""))
            command = ["/bin/bash", str(STAPLER)]
            command.extend(arguments if arguments is not None else [operation, target])
            result = subprocess.run(command, env=environment, capture_output=True,
                                    text=True, timeout=10)
            calls = root / "calls.jsonl"
            sleeps = root / "sleeps.txt"
            return (result,
                    [json.loads(line) for line in calls.read_text().splitlines()] if calls.exists() else [],
                    sleeps.read_text().splitlines() if sleeps.exists() else [], target)

    def test_success_runs_once_and_preserves_target(self):
        for operation in ("staple", "validate"):
            with self.subTest(operation=operation):
                result, calls, sleeps, target = self.run_stapler([(0, "ticket verified")], operation)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(calls, [["stapler", operation, target]])
                self.assertEqual(sleeps, [])
                self.assertIn("ticket verified", result.stdout)

    def test_transport_failures_recover_for_both_operations(self):
        for operation in ("staple", "validate"):
            with self.subTest(operation=operation):
                result, calls, sleeps, target = self.run_stapler(
                    [(68, NETWORK_LOST), (68, TIMEOUT), (0, "recovered")], operation)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(calls, [["stapler", operation, target]] * 3)
                self.assertEqual(sleeps, ["5", "10"])
                self.assertIn(NETWORK_LOST, result.stderr)
                self.assertIn(TIMEOUT, result.stderr)
                self.assertIn("recovered", result.stdout)

    def test_persistent_network_failure_keeps_exit_status(self):
        result, calls, sleeps, _ = self.run_stapler([(68, NETWORK_LOST)])
        self.assertEqual(result.returncode, 68)
        self.assertEqual(len(calls), 4)
        self.assertEqual(sleeps, ["5", "10", "20"])
        self.assertEqual(result.stderr.count(NETWORK_LOST), 4)

    def test_ticket_and_other_errors_are_not_retried(self):
        for status, message in [
            (65, "The ticket data is invalid."),
            (66, "The existing ticket is missing or invalid."),
            (68, "CloudKit's response is inconsistent with expections: (null)"),
            (68, 'Error Domain=OtherDomain Code=-1005'),
            (68, 'Error Domain=NSURLErrorDomain Code=-10050'),
            (73, "The ticket could not be written out to disk."),
            (77, "The ticket has been revoked."),
            (65, NETWORK_LOST),
        ]:
            with self.subTest(status=status, message=message):
                result, calls, sleeps, _ = self.run_stapler([(status, message)])
                self.assertEqual(result.returncode, status)
                self.assertEqual(len(calls), 1)
                self.assertEqual(sleeps, [])
                self.assertIn(message, result.stderr)

    def test_permanent_error_after_transport_failure_stops_immediately(self):
        result, calls, sleeps, _ = self.run_stapler(
            [(68, NETWORK_LOST), (77, "The ticket has been revoked."), (0, "unexpected")])
        self.assertEqual(result.returncode, 77)
        self.assertEqual(len(calls), 2)
        self.assertEqual(sleeps, ["5"])

    def test_invalid_arguments_do_not_invoke_stapler(self):
        for arguments in ([], ["staple"], ["invalid", "App.app"], ["validate", "App.app", "extra"]):
            with self.subTest(arguments=arguments):
                result, calls, sleeps, _ = self.run_stapler([(0, "unexpected")], arguments=arguments)
                self.assertEqual(result.returncode, 64)
                self.assertEqual(calls, [])
                self.assertEqual(sleeps, [])


if __name__ == "__main__":
    unittest.main()
