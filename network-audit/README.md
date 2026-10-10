# network-audit v1

A Python CLI with a mitmproxy addon and Jinja2 report templates. The pinned
Nix flake or devenv supplies Python, Jinja2, mitmproxy and OpenSSL; no pip install,
Flutter app modification, proxy override or `badCertificateCallback` is needed.

## Run

Install or run the self-contained flake on a supported host as described in
[Nix distribution](../README.md#install-or-run-with-nix):

```sh
nix run github:thekorn/network-audit -- /path/to/app.apk --domain api.example.com
```

The default flake package includes the emulator and image; it needs no
`devenv.local.nix`. For source development with devenv instead:

On an Apple Silicon Mac or an x86_64 Linux machine with readable/writable
`/dev/kvm`, set `androidEmulator.enable = true;` in the repository's ignored
`devenv.local.nix`. Enter `devenv shell` from the repository root:

```sh
network-audit sample-app
network-audit sample-app --domain '*.bunte.de' --domain dummyjson.com
network-audit /path/to/app.apk --domain api.example.com
```

The app argument is a Flutter project directory with a committed `pubspec.lock`,
or an already-built APK with a launcher activity. Package and activity names are
read from the APK, not guessed from the source. This version uses the declared
API 36 Google APIs image: ARM64 (`arm64-v8a`) on Apple Silicon, `x86_64` on Linux,
not Google Play or physical devices. Prebuilt APKs must support the selected ABI
(or contain no native code); the default Flutter build includes both.

macOS uses its built-in Hypervisor.Framework, not `/dev/kvm`. Run Nix/devenv
natively on Apple Silicon, not under Rosetta; Intel Macs are not supported by
the pinned Nix Flutter/Android packages. Android Studio is not required for this
Android workflow. `emulator -accel-check` should report
that Hypervisor.Framework is usable. The CLI checks acceleration and the image
before starting the build. The image is selected by the flake or devenv via
`NETWORK_AUDIT_SYSTEM_IMAGE`; do not override it or install SDK components by hand.

Put defaults in the app directory (or beside an APK) as `network-audit.toml`:

```toml
domains = ["*.bunte.de", "dummyjson.com"]
```

`--domain` may be repeated and **replaces** the configuration. Exact names match
only that host; `*.bunte.de` matches `www.bunte.de` and deeper subdomains, not
`bunte.de` itself. Include the apex separately when needed. Domain names are
case-insensitive; use punycode for internationalized names. URL paths, schemes,
ports and arbitrary globs are rejected.

The command builds the debug app, starts mitmproxy on loopback, creates a fresh
temporary AVD, boots it, installs a new CA in its in-memory system trust store
and Conscrypt/Zygote mount namespaces, installs the APK and launches it.
The emulator's network-level `-http-proxy` catches TCP connections even from
Dart clients that ignore Android's system proxy. Non-allowlisted hosts pass
through without interception. UDP port 443 is rejected inside this disposable
emulator so clients with HTTP/3 support fall back to HTTPS over TCP.

Interact with the emulator normally. **Leaving the app in the background for
five seconds finishes the capture**, even if Android keeps its process alive.
This includes Home, switching to another app, or locking the screen. A short
permission dialog can be dismissed before the grace expires. Back on Android
does not necessarily kill an app. Use `--close-grace 30` for longer excursions.
Ctrl+C also ends the session and produces a report. `--headless` hides the
emulator window for ADB-driven automation. On Linux without `DISPLAY` (for
example, an SSH session without X forwarding), headless mode is automatic and
the CLI prints a notice instead of letting Qt crash during boot. The pinned
Linux emulator needs X11/XWayland for its window; to interact graphically, run
from a desktop terminal with a working `DISPLAY` and omit `--headless`.
macOS still opens a window by default. A configured but unreachable Linux
display is not automatically ignored; use `--headless` explicitly in that case.
The device serial is printed and written to the session metadata. In headless
mode, use `adb -s <serial> shell input keyevent KEYCODE_HOME` to leave the app
and finish the audit, or press Ctrl+C.

## Output and safety

Each run creates `.network-audit/runs/<UTC timestamp>-<unique suffix>/` with mode
0700. `--output /some/directory` changes the parent directory. Files are created
with a private umask:

- `report.html`: self-contained offline report with host/status/search filters,
  expandable request/response headers, trailers, text or base64 bodies, status,
  timing, wire sizes and diagnostics. Untrusted content is escaped and rendered
  as text, never as HTML. Binary content is not executed or embedded.
- `report.txt`: request counts per captured hostname, most frequent first, plus
  a total. Subdomains stay separate. Each request counts once, including failed
  and unfinished requests; TLS diagnostics are not requests. The same summary
  prints to stdout at the end of each session, including interrupted or failed
  sessions, and when regenerating reports. Empty captures show a total of zero.
- `events.jsonl`: flushed request/response records, including failures and
  in-flight requests. A later record for the same ID replaces its earlier state.
- `flows.mitm`: complete selected HTTP flows for analysis with `mitmweb -r` or
  `mitmdump -r`. Full captured bodies remain here even when previews are limited.
- `session.json`, `emulator.log`, `proxy.log`: session state and diagnostics.
  mitmproxy's console warnings and the captured traffic print to the terminal;
  `proxy.log` contains its stderr.

Text bodies are decoded (including compression). The terminal and HTML preview
limit defaults to 1 MiB of wire bytes / 1 Mi characters of decoded text per
message, with visible truncation notices. Use `--body-limit N` to change it.
Headers are stored as pairs so duplicate headers, such as Set-Cookie, survive.
All complete selected flows are buffered by mitmproxy; v1 is for bounded manual
sessions, not multi-gigabyte downloads, unbounded streams or load testing.

**Reports and raw captures contain unredacted cookies, tokens, URLs and bodies.**
Keep them private and inspect them before sharing. Do not commit captures.
CA private keys are isolated in a temporary directory and are not part of the
report; the temporary AVD, CA and proxy are removed/stopped on normal completion,
Ctrl+C, SIGTERM or a handled failure. Existing AVDs and host trust stores are not
changed. Like other processes, it cannot clean up after SIGKILL or host power
loss; a new run never adopts or kills an older run's emulator.

Regenerate HTML and text reports after an interrupted run without an emulator:

```sh
network-audit report .network-audit/runs/<session>
```

## Limits

- Apple Silicon macOS/Hypervisor.Framework or x86_64 Linux/KVM and the declared
  rootable API 36 image only. Never enable or run the emulator in an Amp orb;
  agents working in orbs use `thekorn-amp-runner` for native verification. Agents
  on Apple Silicon Macs may run the emulator directly.
- No bypass of certificate pinning, custom certificate stores, mutual TLS or
  apps that explicitly reject interception. TLS failures appear as diagnostics
  when the selected hostname is known, not as invented HTTP responses.
- Captures selected domains across the **whole dedicated emulator**, not proven
  per-process attribution. DNS, arbitrary TCP/UDP and WebSocket frames are not
  reported. A WebSocket HTTP upgrade may be visible.
- The emulator proxy handles TCP. Blocking UDP/443 encourages QUIC fallback,
  but cannot make a UDP-only or nonstandard-port client capturable.
- A zero-exchange report is not proof that an app made no requests. Check scope,
  TLS diagnostics, certificate pinning and proxy/emulator logs.
- Slow or streaming responses still open at shutdown are marked incomplete.
  HTTP 4xx/5xx are retained as responses; transport errors are separate.

## Checks

From the repository root:

```sh
nix flake check
devenv test
devenv shell pyright
python3 -m unittest discover -s network-audit/tests -v
```

`nix flake check` builds and tests the core distribution without an emulator
image, including installed-command/report checks outside the source tree.
`devenv test` includes Pyright and the Python tests. Pyright checks the tool and
its tests in standard mode, using the Python version and dependencies supplied
by the pinned devenv environment. Inside `devenv shell`, run `pyright` directly;
for editor checks, launch the editor from that shell and select its `python3`
interpreter so Jinja2 and mitmproxy imports resolve.

The tests use real mitmdump and local HTTP/TLS servers. They check hostname
boundaries, compressed responses, repeated headers, binary POSTs, upstream
disconnects, truncation versus full raw flows, safe HTML, and CONNECT-to-IP with
hostname SNI and trusted certificates (the emulator's proxy transport). Host
preflight tests cover macOS without KVM, Linux with/without KVM, unsupported
hosts, missing system images and unavailable hardware acceleration.

Native acceptance: run `network-audit sample-app`, verify ten successful
`dummyjson.com/products/<1..10>` responses, open BUNTE and inspect its responses,
press Home, then confirm the report appears and the owned emulator/proxy exit.
Run once more and finish with Ctrl+C to check the alternate stop path.

CA installation follows the temporary mount-namespace approach described in
[Android 14 CA injection](https://httptoolkit.com/blog/android-14-install-system-ca-certificate/).
