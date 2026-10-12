"""Public CLI contracts, also run against the installed Nix wrapper off-tree."""

import json
import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BINARY = os.environ.get("NETWORK_AUDIT_ZIG_BIN", str(ROOT / "zig-out/bin/network-audit-zig"))


class CliTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="zig-cli-")
        self.addCleanup(self.temporary.cleanup)
        self.path = Path(self.temporary.name)
        # The installed wrapper must work without caller PATH, SDK or checkout.
        self.env = {"HOME": str(self.path)}
        if "NETWORK_AUDIT_ZIG_BIN" not in os.environ:
            self.env.update(
                {key: value for key, value in os.environ.items()
                 if key == "PATH" or key.startswith("NETWORK_AUDIT_")}
            )
            self.env["NETWORK_AUDIT_ASSETS"] = str(ROOT.parent / "network-audit")
            self.env["NETWORK_AUDIT_ZIG_CONFIG"] = str(ROOT / "scenario_config.py")

    def run_cli(self, *args):
        return subprocess.run(
            [BINARY, *map(str, args)], cwd=self.path, env=self.env,
            capture_output=True, text=True, timeout=60,
        )

    def test_help_and_invalid_arguments_do_not_start_a_session(self):
        result = self.run_cli("--help")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Zig 0.17", result.stdout)
        for args, diagnostic in [
            ([], "Missing Flutter project or APK"),
            (["app", "--body-limit=0"], "must be positive"),
            (["app", "--scenario-timeout", "nan"], "positive and finite"),
            (["app", "--dimensions", "unknown"], "Unknown dimensions"),
            (["report", "session", "--record"], "Unexpected report option"),
        ]:
            with self.subTest(args=args):
                result = self.run_cli(*args)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(diagnostic, result.stderr)
        self.assertFalse((self.path / ".network-audit").exists())

    def test_report_recovers_events_and_is_private_safe_and_offline(self):
        session = self.path / "session with spaces"
        session.mkdir()
        metadata = {
            "app": "<img src=x onerror=alert(1)>@@h1_app@@",
            "domains": None, "state": "failed", "started": "2026-10-12T10:00:00Z",
            "failure": "</script><script>alert(1)</script>",
        }
        (session / "session.json").write_text(json.dumps(metadata))
        first = {
            "id": "a", "host": "assets.test", "started": 20, "error": None,
            "response": None, "url": "https://assets.test/a/../b?q=one+two&q=&flag&x=%FF",
        }
        events = [
            first, {**first, "response": {"status": 200, "bytes": 2048}},
            {**first, "id": "b", "host": "api.test", "started": 10},
            {**first, "id": "c", "host": "api.test", "started": 30},
            {"diagnostic": "TLS client failure"},
        ]
        original = "\n".join(json.dumps(event) for event in events) + '\n{"id":'
        (session / "events.jsonl").write_text(original)
        result = self.run_cli("report", session.name)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines()[0], str(session / "report.html"))
        summary = "Requests per domain:\napi.test: 2\nassets.test: 1\nTotal requests: 3\n"
        self.assertEqual((session / "report.txt").read_text(), summary)
        self.assertTrue(result.stdout.endswith(summary))
        html = (session / "report.html").read_text()
        self.assertIn("&lt;img", html)
        self.assertNotIn("<script>alert", html)
        self.assertIn("Unreadable capture record at line 6", html)
        data = re.search(r'<script type="application/json" id="audit-data">(.*?)</script>', html, re.S)
        self.assertIsNotNone(data)
        assert data is not None
        flows = json.loads(data[1])["flows"]
        self.assertEqual([flow["id"] for flow in flows], ["b", "a", "c"])
        self.assertEqual(flows[1]["url_parts"], {
            "path": "/a/../b", "query": [["q", "one two"], ["q", ""], ["flag", ""], ["x", "�"]],
        })
        self.assertEqual((session / "events.jsonl").read_text(), original)
        self.assertEqual((session / "report.html").stat().st_mode & 0o777, 0o600)
        self.assertNotRegex(html, r'<(?:script|link)[^>]+(?:src|href)="https?://')

    def test_scenarios_use_bundled_schema_and_node_before_android_preflight(self):
        apk = self.path / "app.apk"
        apk.touch()
        scenarios = self.path / "scenarios"
        scenarios.mkdir()
        definition = scenarios / "audit.toml"
        executor = scenarios / "run.mjs"
        executor.write_text("export default async function () {}\n")
        definition.write_text('domains = ["example.test"]\n')
        result = self.run_cli(apk, "--scenario", definition)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("'executor' is a required property", result.stderr)
        definition.write_text('executor = "run.mjs"\nextra = true\n')
        result = self.run_cli(apk, "--scenario", definition)
        self.assertIn("Additional properties", result.stderr)
        executor.write_text("export default async function ( {\n")
        definition.write_text('executor = "run.mjs"\n')
        result = self.run_cli(apk, "--scenario", definition)
        self.assertIn("Invalid executor syntax:", result.stderr)
        self.assertIn("SyntaxError", result.stderr)
        executor.write_text("export default async function () {}\n")
        # This uses actual TOML table syntax, not just the README's inline form.
        definition.write_text('executor = "run.mjs"\nflavor = "stage"\n[dimensions]\nwidth = 1280\nheight = 2856\ndensity = 480\n')
        result = self.run_cli(apk, "--scenario", definition)
        self.assertIn("requires a Flutter project, not an APK", result.stderr)
        definition.write_text('executor = "run.mjs"\n[dimensions]\nwidth = 1000000000000000000000000\nheight = 2856\ndensity = 480\n')
        result = self.run_cli(apk, "--scenario", definition)
        self.assertEqual(result.returncode, 1)
        self.assertIn("dimensions exceed the supported 32-bit range", result.stderr)
        self.assertFalse((self.path / ".network-audit").exists())


if __name__ == "__main__":
    unittest.main()
