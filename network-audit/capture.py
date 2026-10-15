"""mitmdump addon. Filtered audit files and an optional all-host session HAR."""

import base64
import json
import os
import sys
import time
from pathlib import Path

from mitmproxy import io
from mitmproxy.addons.savehar import SaveHar

sys.path.insert(0, str(Path(__file__).resolve().parent))
from domains import matches


def message_data(message, limit):
    raw = message.raw_content
    try:
        decoded = message.get_content(strict=False)
        text = message.get_text(strict=False) if decoded is not None else None
    except ValueError:
        decoded, text = raw, None
    content_type = message.headers.get("content-type", "")
    is_text = any(
        t in content_type.lower()
        for t in ("text/", "json", "xml", "javascript", "form-urlencoded")
    )
    return {
        "headers": list(message.headers.items(multi=True)),
        "trailers": list(message.trailers.items(multi=True))
        if message.trailers
        else [],
        "http_version": message.http_version,
        "bytes": len(raw) if raw is not None else None,
        "body_base64": base64.b64encode((raw or b"")[:limit]).decode(),
        "body_text": text[:limit] if is_text and text is not None else None,
        "truncated": len(raw or b"") > limit or len(text or "") > limit,
        "missing": raw is None,
    }


def console_text(value):
    # Network data must not be able to inject terminal escape sequences.
    return "".join(
        c
        if c in "\n\t" or (ord(c) >= 32 and not 127 <= ord(c) <= 159)
        else f"\\x{ord(c):02x}"
        for c in str(value)
    )


class Capture:
    def __init__(self):
        self.directory = Path(os.environ["NETWORK_AUDIT_SESSION"])
        self.domains = json.loads(os.environ["NETWORK_AUDIT_DOMAINS"])
        self.limit = int(os.environ["NETWORK_AUDIT_BODY_LIMIT"])
        self.events = (self.directory / "events.jsonl").open("a", buffering=1)
        self.raw = (self.directory / "flows.mitm").open("wb")
        self.writer = io.FlowWriter(self.raw)
        self.pending = {}
        self.har_flows = {} if os.environ.get("NETWORK_AUDIT_OUTPUT_HAR") == "1" else None

    def running(self):
        (self.directory / "proxy.ready").touch()

    def emit(self, record):
        self.events.write(json.dumps(record, ensure_ascii=True) + "\n")

    def requestheaders(self, flow):
        # Retain live flows independently of the report filter, even uploads
        # or responses still in progress when capture ends. Native hardump
        # only collects completed/errored flows and would omit pending ones.
        if self.har_flows is not None:
            self.har_flows[flow.id] = flow

    def request(self, flow):
        if not matches(flow.request.pretty_host, self.domains):
            return
        self.pending[flow.id] = flow
        self.emit(self.record(flow))
        self.print_message(
            f">>> {flow.request.method} {flow.request.pretty_url}",
            message_data(flow.request, self.limit),
        )

    def record(self, flow):
        response = flow.response
        end = response.timestamp_end if response else None
        return {
            "id": flow.id,
            "host": flow.request.pretty_host,
            "method": flow.request.method,
            "url": flow.request.pretty_url,
            "started": flow.request.timestamp_start,
            "duration_ms": round((end - flow.request.timestamp_start) * 1000, 1)
            if end
            else None,
            "request": message_data(flow.request, self.limit),
            "response": {
                **message_data(response, self.limit),
                "status": response.status_code,
            }
            if response
            else None,
            "error": str(flow.error) if flow.error else None,
        }

    def print_message(self, title, message):
        lines = ["\n" + title, *[f"{k}: {v}" for k, v in message["headers"]]]
        if message["body_text"] is not None:
            lines.extend(["", message["body_text"]])
        elif message["bytes"]:
            lines.extend(["", "[binary body, base64] " + message["body_base64"]])
        if message["truncated"]:
            lines.append("[preview truncated; full body in flows.mitm]")
        print(console_text("\n".join(lines)), flush=True)

    def response(self, flow):
        self.finish(flow)

    def error(self, flow):
        self.finish(flow)

    def finish(self, flow):
        if flow.id not in self.pending:
            return
        self.pending.pop(flow.id)
        self.emit(self.record(flow))
        self.writer.add(flow)
        self.raw.flush()
        if flow.response:
            self.print_message(
                f"<<< {flow.response.status_code} {flow.request.pretty_url}",
                message_data(flow.response, self.limit),
            )
        else:
            print(
                console_text(f"<<< ERROR {flow.request.pretty_url}: {flow.error}"),
                flush=True,
            )

    def tls_failed_client(self, data):
        self.tls_error(data, "client")

    def tls_failed_server(self, data):
        self.tls_error(data, "server")

    def tls_error(self, data, side):
        host = data.context.client.sni or data.context.server.sni or ""
        if matches(host, self.domains):
            self.emit(
                {
                    "diagnostic": f"TLS {side} failure for {host}: {data.conn.error}",
                    "time": time.time(),
                }
            )

    def done(self):
        for flow in self.pending.values():
            record = self.record(flow)
            record["error"] = "Capture ended before the response completed"
            self.emit(record)
            self.writer.add(flow)
        self.events.close()
        self.raw.close()
        if self.har_flows is not None:
            flows = list(self.har_flows.values())
            har = SaveHar().make_har(flows)
            for flow, entry in zip(flows, har["log"]["entries"]):
                if flow.error:
                    entry["response"]["_error"] = str(flow.error)
                elif not flow.response or flow.response.timestamp_end is None:
                    entry["response"]["_error"] = "Capture ended before the response completed"
            # Only publish a complete HAR. The CLI treats a missing final file
            # as a failure, including addon errors and forced proxy shutdown.
            partial = self.directory / "session.har.partial"
            partial.write_text(json.dumps(har, ensure_ascii=True, indent=2) + "\n")
            partial.replace(self.directory / "session.har")


addons = [Capture()]
