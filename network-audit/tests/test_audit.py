import base64
import gzip
import http.client
import json
import os
import re
import shutil
import signal
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from domains import matches, normalize_domains, proxy_pattern
from report import generate_report, read_events

ROOT = Path(__file__).resolve().parents[1]


class DomainsTest(unittest.TestCase):
    def test_exact_and_wildcard_have_hostname_boundaries(self):
        domains = normalize_domains(["*.BUNTE.de", "dummyjson.com."])
        for host in ("www.bunte.de", "a.b.bunte.de", "dummyjson.com"):
            self.assertTrue(matches(host, domains), host)
            self.assertIsNotNone(re.fullmatch(proxy_pattern(domains), host + ":443"))
        for host in (
            "bunte.de",
            "evilbunte.de",
            "dummyjson.com.attacker.net",
            "sub.dummyjson.com",
            "127.0.0.1",
        ):
            self.assertFalse(matches(host, domains), host)
            self.assertIsNone(re.fullmatch(proxy_pattern(domains), host + ":443"))
        for invalid in (
            "https://bunte.de",
            "*bunte.de",
            "foo:443",
            "foo..com",
            "x/",
            "-foo.com",
        ):
            with self.assertRaises(ValueError):
                normalize_domains([invalid])
        for invalid in ("example.com", None, [123], []):
            with self.assertRaises(ValueError):
                normalize_domains(invalid)


class ReportTest(unittest.TestCase):
    def test_empty_and_interrupted_reports_escape_network_data(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            (path / "session.json").write_text(
                json.dumps(
                    {
                        "app": "<img src=x onerror=alert(1)>@@DATA@@",
                        "domains": ["example.test"],
                        "started": "2026-10-10T10:00:00Z",
                        "state": "failed",
                        "failure": "</script><script>alert(1)</script>",
                    }
                )
            )
            report = generate_report(path).read_text()
            self.assertIn("&lt;img", report)
            self.assertNotIn("<script>alert(1)</script>", report)
            self.assertIn('"flows": []', report)
            (path / "events.jsonl").write_text('{"id":')
            self.assertIn(
                "Unreadable capture record", generate_report(path).read_text()
            )


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def handle(self):
        try:
            super().handle()
        except (BrokenPipeError, ConnectionResetError):
            # The untrusted-client test deliberately aborts TLS while mitmproxy
            # may already have an idle origin connection for certificate lookup.
            pass

    def log_message(self, format, *args):
        pass

    def do_GET(self):
        if self.path == "/disconnect":
            self.connection.shutdown(socket.SHUT_RDWR)
            self.connection.close()
            return
        body = gzip.compress(
            b'{"answer":42,"markup":"</script><img src=x onerror=alert(1)>"}'
        )
        self.send_response(418 if self.path == "/error" else 200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Encoding", "gzip")
        self.send_header("Set-Cookie", "first=1")
        self.send_header("Set-Cookie", "second=2")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        body = self.rfile.read(int(self.headers["Content-Length"]))
        self.send_response(201)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


@contextmanager
def proxy_session(directory, extra=(), limit=1048576):
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    ca = directory / "ca"
    env = {
        **os.environ,
        "NETWORK_AUDIT_SESSION": str(directory),
        "NETWORK_AUDIT_DOMAINS": '["localhost"]',
        "NETWORK_AUDIT_BODY_LIMIT": str(limit),
    }
    with (directory / "console.log").open("w") as log:
        process = subprocess.Popen(
            [
                "mitmdump",
                "-q",
                "--listen-host",
                "127.0.0.1",
                "--listen-port",
                str(port),
                "--set",
                f"confdir={ca}",
                "--set",
                f"allow_hosts={proxy_pattern(['localhost'])}",
                "-s",
                str(ROOT / "capture.py"),
                *extra,
            ],
            env=env,
            stdout=log,
            stderr=log,
        )
        try:
            deadline = time.monotonic() + 20
            while not (directory / "proxy.ready").exists():
                if process.poll() is not None or time.monotonic() > deadline:
                    raise RuntimeError((directory / "console.log").read_text())
                time.sleep(0.1)
            yield port, ca
        finally:
            process.send_signal(signal.SIGINT)
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()


@unittest.skipUnless(shutil.which("mitmdump"), "mitmdump is supplied by devenv")
class CaptureTest(unittest.TestCase):
    def test_http_capture_filter_errors_binary_and_full_raw_flow(self):
        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        try:
            with tempfile.TemporaryDirectory() as directory:
                path = Path(directory)
                origin_port = server.server_port
                with proxy_session(path, limit=20) as (port, _):
                    for host, endpoint, expected in (
                        ("localhost", "/ok", 200),
                        ("localhost", "/error", 418),
                        ("127.0.0.1", "/excluded", 200),
                        ("localhost", "/disconnect", 502),
                    ):
                        conn = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
                        conn.request("GET", f"http://{host}:{origin_port}{endpoint}")
                        response = conn.getresponse()
                        self.assertEqual(response.status, expected)
                        response.read()
                        conn.close()
                    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
                    body = bytes(range(256))
                    conn.request(
                        "POST",
                        f"http://localhost:{origin_port}/binary",
                        body,
                        {"Content-Type": "application/octet-stream"},
                    )
                    self.assertEqual(conn.getresponse().read(), body)
                    conn.close()
                flows, diagnostics = read_events(path / "events.jsonl")
                self.assertEqual(len(flows), 4)
                self.assertEqual(diagnostics, [])
                ok = next(f for f in flows if f["url"].endswith("/ok"))
                self.assertEqual(ok["response"]["status"], 200)
                self.assertTrue(ok["response"]["body_text"].startswith('{"answer":42'))
                self.assertTrue(ok["response"]["truncated"])
                cookies = [
                    v for k, v in ok["response"]["headers"] if k.lower() == "set-cookie"
                ]
                self.assertEqual(cookies, ["first=1", "second=2"])
                self.assertTrue(
                    next(f for f in flows if f["url"].endswith("/disconnect"))["error"]
                )
                binary = next(f for f in flows if f["method"] == "POST")
                self.assertEqual(
                    base64.b64decode(binary["request"]["body_base64"]), body[:20]
                )
                self.assertEqual(binary["response"]["bytes"], 256)
                self.assertIn(body, (path / "flows.mitm").read_bytes())
                self.assertNotIn("/excluded", (path / "console.log").read_text())
        finally:
            server.shutdown()
            server.server_close()

    def test_tls_connect_to_ip_uses_sni_and_installed_ca(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            cert, key = path / "origin.pem", path / "origin.key"
            subprocess.run(
                [
                    "openssl",
                    "req",
                    "-x509",
                    "-newkey",
                    "rsa:2048",
                    "-nodes",
                    "-keyout",
                    str(key),
                    "-out",
                    str(cert),
                    "-days",
                    "1",
                    "-subj",
                    "/CN=localhost",
                    "-addext",
                    "subjectAltName=DNS:localhost",
                ],
                check=True,
                capture_output=True,
            )
            server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            context.load_cert_chain(cert, key)
            server.socket = context.wrap_socket(server.socket, server_side=True)
            threading.Thread(target=server.serve_forever, daemon=True).start()
            try:
                with proxy_session(
                    path, ["--set", f"ssl_verify_upstream_trusted_ca={cert}"]
                ) as (port, ca):
                    # Match the emulator: CONNECT to an IP, then TLS with hostname SNI.
                    sock = socket.create_connection(("127.0.0.1", port), timeout=10)
                    sock.sendall(
                        f"CONNECT 127.0.0.1:{server.server_port} HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".encode()
                    )
                    headers = b""
                    while not headers.endswith(b"\r\n\r\n"):
                        chunk = sock.recv(1)
                        self.assertTrue(chunk, "Proxy closed the CONNECT tunnel")
                        headers += chunk
                    self.assertIn(b"200", headers)
                    trusted = ssl.create_default_context(
                        cafile=str(ca / "mitmproxy-ca-cert.pem")
                    )
                    tls = trusted.wrap_socket(sock, server_hostname="localhost")
                    tls.sendall(
                        b"GET /tls HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
                    )
                    response = http.client.HTTPResponse(tls)
                    response.begin()
                    self.assertEqual(response.status, 200)
                    self.assertEqual(
                        json.loads(gzip.decompress(response.read()))["answer"], 42
                    )
                    tls.close()
                    # A client without our CA must fail, and produce a TLS
                    # diagnostic rather than an invented HTTP exchange.
                    untrusted = http.client.HTTPSConnection(
                        "127.0.0.1",
                        port,
                        timeout=10,
                        context=ssl.create_default_context(),
                    )
                    untrusted.set_tunnel("localhost", server.server_port)
                    with self.assertRaises(ssl.SSLCertVerificationError):
                        untrusted.request("GET", "/untrusted")
                    untrusted.close()
                flows, diagnostics = read_events(path / "events.jsonl")
                self.assertEqual(len(flows), 1)
                self.assertTrue(
                    any("TLS client failure for localhost" in d for d in diagnostics)
                )
                self.assertEqual(flows[0]["host"], "localhost")
                self.assertIn('"answer":42', flows[0]["response"]["body_text"])
                (path / "session.json").write_text(
                    json.dumps(
                        {
                            "app": "TLS contract",
                            "domains": ["localhost"],
                            "started": "2026-10-10",
                            "state": "complete",
                        }
                    )
                )
                report = generate_report(path).read_text()
                self.assertNotIn("</script><img src=x", report)
                self.assertIn("\\u003c/script\\u003e", report)
            finally:
                server.shutdown()
                server.server_close()


if __name__ == "__main__":
    unittest.main()
