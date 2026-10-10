"""Offline HTML report and text summary. Captured content is data, never HTML."""

import json
from collections import Counter
from pathlib import Path

from jinja2 import Environment, FileSystemLoader, StrictUndefined


def read_events(path):
    flows, diagnostics = {}, []
    if not path.exists():
        return [], diagnostics
    for number, line in enumerate(path.read_text().splitlines(), 1):
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            diagnostics.append(
                f"Unreadable capture record at line {number} (possibly interrupted write)"
            )
            continue
        if "diagnostic" in event:
            diagnostics.append(event["diagnostic"])
        else:
            flows[event["id"]] = event
    return sorted(flows.values(), key=lambda f: f["started"]), diagnostics


def generate_report(session):
    session = Path(session)
    metadata = json.loads((session / "session.json").read_text())
    flows, diagnostics = read_events(session / "events.jsonl")
    if metadata.get("failure"):
        diagnostics.insert(0, metadata["failure"])
    if not flows:
        diagnostics.append(
            "No matching HTTP exchanges captured. This does not prove the app made no network requests; check the domain filters and TLS diagnostics."
        )
    counts = Counter(flow["host"] for flow in flows)
    errors = sum(
        bool(f["error"]) or not f["response"] or f["response"]["status"] >= 400
        for f in flows
    )
    total_bytes = sum((f["response"] or {}).get("bytes") or 0 for f in flows)
    environment = Environment(
        loader=FileSystemLoader(Path(__file__).resolve().parent),
        autoescape=True,
        undefined=StrictUndefined,
        keep_trailing_newline=True,
    )
    output = environment.get_template("report.html.jinja").render(
        metadata=metadata,
        flows=flows,
        diagnostics=diagnostics,
        host_counts=counts.most_common(),
        max_host_count=max(counts.values(), default=0),
        errors=errors,
        total_bytes=total_bytes,
    )
    path = session / "report.html"
    path.write_text(output)
    summary = ["Requests per domain:"]
    summary.extend(f"{host}: {count}" for host, count in counts.most_common())
    if not counts:
        summary.append("No matching HTTP requests captured.")
    summary.append(f"Total requests: {len(flows)}")
    (session / "report.txt").write_text("\n".join(summary) + "\n")
    return path
