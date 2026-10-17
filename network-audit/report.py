"""Offline HTML report and text summary. Captured content is data, never HTML."""

import json
from collections import Counter
from pathlib import Path
from urllib.parse import parse_qsl, urlsplit

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


def read_ad_events(path):
    """An append-only evidence ledger, independent of HTTP flow snapshots."""
    result = {"collected": path.exists(), "records": [], "documents": [],
              "diagnostics": [], "captures": []}
    if not path.exists():
        return result
    documents, captures = {}, {}
    for number, line in enumerate(path.read_text(errors="replace").splitlines(), 1):
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            result["diagnostics"].append(f"Malformed ad record at line {number}; later records retained.")
            continue
        index = len(result["records"])
        result["records"].append(event)
        if not isinstance(event, dict) or type(event.get("schemaVersion")) is not int or event["schemaVersion"] != 1:
            result["diagnostics"].append(f"Unsupported ad schema at line {number}; raw evidence retained.")
            continue
        capture_id = event.get("captureId")
        key = json.dumps(capture_id, sort_keys=True)
        capture = captures.setdefault(key, {"captureId": capture_id, "records": [], "partial": True})
        capture["records"].append(index)
        if not isinstance(event.get("data"), dict):
            result["diagnostics"].append(f"Invalid ad payload at line {number}; raw evidence retained.")
            continue
        if event.get("source") == "host":
            if event.get("type") == "captureStopped":
                data = event.get("data") or {}
                capture["partial"] = data.get("flushed") is not True or bool(data.get("disconnected"))
            continue
        if not event.get("documentId"):
            result["diagnostics"].append(f"Missing document identity at line {number}; raw evidence retained.")
            continue
        key = json.dumps([capture_id, event["documentId"]], sort_keys=True)
        document = documents.setdefault(key, {
            "captureId": capture_id, "documentId": event["documentId"],
            "records": [], "diagnostics": [], "partial": True,
        })
        document["records"].append(index)
        # pagehide flushes a navigation's final snapshot. BFCache restoration
        # resumes this document's sequence, so later records reopen its coverage.
        document["partial"] = event.get("type") not in ("documentStopped", "documentHidden")
    for document in documents.values():
        seen, high = set(), 0
        for index in document["records"]:
            sequence = result["records"][index].get("sequence")
            if type(sequence) is not int or sequence < 1:
                document["diagnostics"].append(f"Invalid sequence at record {index + 1}")
                continue
            if sequence in seen:
                document["diagnostics"].append(f"Duplicate sequence {sequence}")
            elif sequence > high + 1:
                document["diagnostics"].append(f"Sequence gap: expected {high + 1}, observed {sequence}")
            elif sequence < high:
                document["diagnostics"].append(f"Out-of-order sequence {sequence}")
            seen.add(sequence)
            high = max(high, sequence)
    result["documents"] = list(documents.values())
    result["captures"] = list(captures.values())
    return result


def generate_report(session):
    session = Path(session)
    metadata = json.loads((session / "session.json").read_text())
    flows, diagnostics = read_events(session / "events.jsonl")
    ads = read_ad_events(session / "ad-events.jsonl")
    ad_counts = Counter()
    ad_responses = []
    # Count event observations, not repeated prices in snapshots, wins or renders.
    # Use validated document records; unsupported records stay in the raw ledger.
    for document in ads["documents"]:
        for index in document["records"]:
            record = ads["records"][index]
            data = record["data"]
            if record.get("type") == "bidRequested":
                bids = data.get("bids")
                if isinstance(bids, list):
                    ad_counts["requests"] += len(bids)
            elif record.get("type") == "noBid":
                ad_counts["no_bids"] += 1
            elif record.get("type") == "bidResponse":
                bid = data.get("bid")
                bid = bid if isinstance(bid, dict) else {}
                ad_responses.append({"record": record, "bid": bid})
                ad_counts["priced_responses"] += bid.get("cpm") is not None
    for flow in flows:
        try:
            url = urlsplit(flow.get("url", ""))
            flow["url_parts"] = {
                "path": url.path or "/",
                "query": parse_qsl(url.query, keep_blank_values=True),
            }
        except ValueError:
            flow["url_parts"] = None
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
        ads=ads,
        ad_counts=ad_counts,
        ad_responses=ad_responses,
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
