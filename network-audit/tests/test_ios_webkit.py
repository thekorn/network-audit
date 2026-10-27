"""Opt-in native contract test; never run an iOS Simulator in an orb.

NETWORK_AUDIT_TEST_IOS=1 devenv shell -- python3 -m unittest discover \
    -s network-audit/tests -p test_ios_webkit.py -v
"""

import http.client
import os
import platform
import plistlib
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from io import StringIO
from pathlib import Path
from urllib.parse import urlsplit

from test_audit import proxy_session

from android import run, wait_for
from ios import Simulator, check_simulator
from report import read_events


@unittest.skipUnless(sys.platform == "darwin" and os.environ.get("NETWORK_AUDIT_TEST_IOS") == "1", "opt-in Xcode/Simulator check")
class NativeWebKitTest(unittest.TestCase):
    def test_first_navigation_subresources_and_post_are_scoped_to_the_audited_app(self):
        hits = set()

        class Origin(BaseHTTPRequestHandler):
            def log_message(self, format, *args):
                pass

            def do_GET(self):
                hits.add(self.path)
                if self.path.endswith("/main"):
                    body = b'<script src="script"></script><iframe src="frame"></iframe>'
                    content_type = "text/html"
                elif self.path.endswith("/script"):
                    body = b'fetch("post", {method:"POST", body:"webkit-payload"})'
                    content_type = "application/javascript"
                else:
                    body = b"frame or control"
                    content_type = "text/html"
                self.send_response(200)
                self.send_header("Content-Type", content_type)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def do_POST(self):
                body = self.rfile.read(int(self.headers["Content-Length"]))
                hits.add(self.path)
                self.send_response(201)
                self.send_header("Content-Type", "text/plain")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

        def paths(label):
            return {f"/{label}/{kind}/{part}"
                    for kind in ("default", "ephemeral", "named", "shared", "decoded")
                    for part in ("main", "script", "frame", "post")}

        origin = ThreadingHTTPServer(("127.0.0.1", 0), Origin)
        threading.Thread(target=origin.serve_forever, daemon=True).start()
        try:
            configuration = check_simulator()
            with tempfile.TemporaryDirectory(prefix="network-audit-webkit-test-") as directory:
                root = Path(directory)
                app = root / "Fixture.app"
                app.mkdir()
                package = "test.networkAudit.WebKit"
                (app / "Info.plist").write_bytes(plistlib.dumps({
                    "CFBundleIdentifier": package, "CFBundleExecutable": "Fixture",
                    "CFBundlePackageType": "APPL", "CFBundleSupportedPlatforms": ["iPhoneSimulator"],
                    "NSAppTransportSecurity": {"NSAllowsArbitraryLoads": True},
                    "UIApplicationSceneManifest": {"UISceneConfigurations": {
                        "UIWindowSceneSessionRoleApplication": [{
                            "UISceneConfigurationName": "fixture", "UISceneDelegateClassName": "WebKitFixture",
                        }],
                    }},
                }))
                run([
                    "xcrun", "--sdk", "iphonesimulator", "clang", "-fobjc-arc",
                    "-target", f"{platform.machine()}-apple-ios17.0-simulator",
                    "-framework", "UIKit", "-framework", "WebKit",
                    str(Path(__file__).with_name("webkit_app.m")), "-o", str(app / "Fixture"),
                ])
                owned = Simulator(root.name + "-owned", StringIO(), True, configuration)
                other = Simulator(root.name + "-control", StringIO(), True, configuration)
                base = f"http://localhost:{origin.server_port}"

                def reached(label, log):
                    try:
                        wait_for(lambda: paths(label) <= hits, f"{label} reached origin", timeout=45)
                    except RuntimeError:
                        self.fail(f"Missing {paths(label) - hits}\n{log.read_text() if log.exists() else 'No app log'}")

                def direct(device, label, env=None):
                    log = root / f"{label}.log"
                    device.simctl("install", device.serial, str(app))
                    device.simctl("launch", f"--stderr={log}", device.serial, package, env={
                        **(env if env is not None else os.environ),
                        "SIMCTL_CHILD_AUDIT_TEST_BASE": f"{base}/{label}",
                    })
                    reached(label, log)

                try:
                    owned.create()
                    owned.start()
                    other.create()
                    other.start()
                    with proxy_session(root) as (port, _ca):
                        # The page works without the helper but is NOT captured.
                        direct(owned, "before")
                        owned.simctl("terminate", owned.serial, package)
                        owned.prepare_webkit(root, port, package, root)
                        assert owned.webkit is not None
                        owned.webkit.environment["SIMCTL_CHILD_AUDIT_TEST_BASE"] = f"{base}/owned"
                        owned.launch(app, package)
                        reached("owned", owned.webkit.log)

                        # Even accidentally inherited injection must decline a
                        # different Simulator. Its WebViews still reach origin.
                        direct(other, "other", owned.webkit.environment)
                        owned.simctl("terminate", owned.serial, package)
                        direct(owned, "wrong-bundle", {
                            **owned.webkit.environment, "SIMCTL_CHILD_NETWORK_AUDIT_BUNDLE": "another.app",
                        })
                        client = http.client.HTTPConnection("localhost", origin.server_port)
                        client.request("GET", "/host-control")
                        self.assertEqual(client.getresponse().status, 200)
                        client.close()
                        wait_for(lambda: sum(bool(item.get("response")) for item in read_events(root / "events.jsonl")[0]) >= 20, "captured responses", timeout=10)
                    exchanges, diagnostics = read_events(root / "events.jsonl")
                    self.assertFalse(diagnostics)
                    self.assertEqual({urlsplit(item["url"]).path for item in exchanges}, paths("owned"))
                    for item in exchanges:
                        is_post = item["url"].endswith("/post")
                        self.assertEqual(item["response"]["status"], 201 if is_post else 200)
                        if is_post:
                            self.assertEqual(item["response"]["body_text"], "webkit-payload")
                    self.assertTrue(paths("before") | paths("other") | paths("wrong-bundle") | {"/host-control"} <= hits)
                finally:
                    try:
                        other.close()
                    finally:
                        owned.close()
        finally:
            origin.shutdown()
            origin.server_close()
