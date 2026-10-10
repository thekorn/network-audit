"""Offline, self-contained report. Captured content is data, never HTML."""

import json
import re
from collections import Counter
from html import escape
from pathlib import Path


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
    template = Path(__file__).with_name("report.html").read_text()
    data = (
        json.dumps({"flows": flows, "metadata": metadata}, ensure_ascii=True)
        .replace("<", "\\u003c")
        .replace(">", "\\u003e")
        .replace("&", "\\u0026")
    )
    replacements = {
        "TITLE": escape(metadata["app"]),
        "PACKAGE": escape(metadata.get("package", "")),
        "STARTED": escape(metadata["started"]),
        "STATE": escape(metadata["state"]),
        "DOMAINS": " · ".join(escape(d) for d in metadata["domains"]),
        "COUNT": str(len(flows)),
        "ERRORS": str(errors),
        "BYTES": f"{total_bytes / 1024:,.1f} KB",
        "HOSTS": str(len(counts)),
        "BARS": "".join(
            f'<li><span>{escape(host)}</span><meter min="0" max="{max(counts.values())}" value="{count}">{count}</meter><b>{count}</b></li>'
            for host, count in counts.most_common()
        ),
        "DIAGNOSTICS": "".join(f"<p>{escape(d)}</p>" for d in diagnostics),
        "EMPTYDIAGNOSTICS": "false" if diagnostics else "true",
        "DATA": data,
    }
    # One substitution pass: captured strings cannot introduce template tokens.
    output = re.sub(r"@@([A-Z]+)@@", lambda m: replacements[m[1]], template)
    path = session / "report.html"
    path.write_text(output)
    return path
