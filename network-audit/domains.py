"""Hostname-only allowlist shared by the CLI and the mitmproxy addon."""

import re


def normalize_domains(values):
    if not isinstance(values, list) or not all(isinstance(v, str) for v in values):
        raise ValueError("domains must be a list of hostnames")
    domains = []
    for value in values:
        domain = value.strip().lower().rstrip(".")
        host = domain.removeprefix("*.")
        if not re.fullmatch(r"[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?", host):
            raise ValueError(f"Invalid domain {value!r}; use a hostname or *.hostname")
        if any(
            not label or len(label) > 63 or label.startswith("-") or label.endswith("-")
            for label in host.split(".")
        ):
            raise ValueError(f"Invalid domain: {value!r}")
        if domain not in domains:
            domains.append(domain)
    if not domains:
        raise ValueError("No domains configured. Use --domain or --scenario <name>.toml.")
    return domains


def host_pattern(domains):
    # An omitted scenario filter captures every host; an empty list is invalid.
    if domains is None:
        return ".*"
    # *.example.com intentionally excludes the apex example.com.
    return (
        "(?:"
        + "|".join(
            (r"(?:[^.:]+\.)+" + re.escape(d[2:]))
            if d.startswith("*.")
            else re.escape(d)
            for d in domains
        )
        + ")"
    )


def matches(host, domains):
    return re.fullmatch(host_pattern(domains), host.lower().rstrip(".")) is not None


def proxy_pattern(domains):
    return "(?i)^" + host_pattern(domains) + r"\.?(?::\d+)?$"
