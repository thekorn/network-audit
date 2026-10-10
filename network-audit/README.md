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
network-audit sample-app --domain '*.bunte.de' --domain dummyjson.com
network-audit /path/to/app.apk --domain api.example.com
network-audit sample-app --scenario sample-app/scenarios/browse.toml
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

On macOS, the CLI routes ADB through an emulator-owned loopback TCP forward
after boot and verifies the AVD identity before installing anything. This avoids
the pinned ARM64 emulator's vsock transport dropping large transfers, which can
surface as `uiautomator dump: exit status 255`, `device offline`, or even a
successful but truncated `adb exec-out`. The printed serial is therefore
`127.0.0.1:<port>` on macOS; Linux keeps `emulator-<port>`. The forward and ADB
connection are removed during cleanup without restarting the shared ADB server.

Each automated scenario has its own TOML entry point, for example
`sample-app/scenarios/browse.toml`:

```toml
domains = ["*.bunte.de", "dummyjson.com"]
executor = "browse.mjs"
```

Select it with `--scenario sample-app/scenarios/browse.toml`. Both fields are
required: `domains` is a non-empty list of hostnames, and `executor` is the path
to a trusted JavaScript file (`.js` or `.mjs`). The TOML path is relative to your
current working directory; a relative executor path resolves beside the TOML
file, not beside the app or relative to the working directory. Absolute executor
paths also work. Different scenarios can share an executor but log different domains.

The CLI no longer discovers `network-audit.toml` in the app directory or beside
an APK, and `--scenario` no longer accepts a JavaScript file directly. To migrate,
move the old `domains` list into each scenario's TOML and add its `executor` path.
For manual captures without a scenario, specify domains with `--domain`.

`--domain` may be repeated and **replaces** the scenario's domain list; the TOML
must still contain valid `domains` and `executor` fields. Exact names match
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

## Experimental Mobilewright scenarios

Devenv and both flake packages automatically provide Node.js and the same
lockfile-pinned Mobilewright runtime. Nix runs `npm ci` during the runtime build
and caches the result; no manual npm installation or checkout-local
`node_modules` is required. In a devenv shell or with the installed Nix command:

```sh
network-audit sample-app --scenario sample-app/scenarios/browse.toml
# Hide the emulator window and bound the scenario to two minutes:
network-audit sample-app --headless --scenario sample-app/scenarios/browse.toml --scenario-timeout 120
```

Or run a scenario directly with the full flake package on a supported host:

```sh
nix run . -- /path/to/app.apk --scenario /path/to/scenario.toml
```

The same disposable emulator, capture setup and HTML report are used. The CLI
launches the app first, then Mobilewright attaches without restarting it.
Mobilecli identifies an emulator transport by its unique AVD name on Linux,
or by its loopback TCP serial on macOS.
A scenario's completion ends capture automatically;
`--close-grace` does not apply in scenario mode, so system dialogs or temporary
app switches do not end an automated run. The timeout defaults to 300 seconds
starting after app launch, including module loading and Mobilewright connection.
There is no implicit delay after completion: await any desired capture window
in the scenario itself.

The sample waits for ten successful product requests, scrolls down the feed,
returns to **Run 10 GETs again** and refreshes it, opens BUNTE, accepts its consent,
declines the optional push-notification prompt if it appears within ten seconds,
scrolls the WebView twice and waits five seconds. It deliberately fails if a
product batch fails or the expected consent button cannot be found; it never
silently skips consent. BUNTE is a live external site, so its wording, prompts
and availability can change. Accepting consent allows the site's advertising
and tracking in this disposable emulator.

**Prior native verification:** the sample's JavaScript executor completed on fresh
Android 36 ARM64 emulators on macOS before the move to per-scenario TOML entry
points, including a repeat using `devenv shell audit`. Those captures contain twenty successful product GETs
(two per product); the final screenshot shows BUNTE content after consent and
WebView scrolling.
The macOS runner uses native Android accessibility throughout the scenario,
rather than Mobilecli's Flutter render tree. The Linux driver and transport are
unchanged and were not retested for this fix. Earlier x86_64 verification reached
consent but failed with `error: device offline`; this macOS verification does not
resolve or retest that earlier Linux failure.

Scenarios are **trusted local code**, not a sandboxed data format. Only run files
you trust: they inherit your host environment and can access files and network.
Executors export one async function. Prefer `.mjs` ES modules; `.js` is also
accepted using Node's normal module rules (including the nearest `package.json`
`type` field). For example, place these two files together:

```toml
# my-scenario.toml
domains = ["api.example.com"]
executor = "my-scenario.mjs"
```

```js
// my-scenario.mjs
import { setTimeout as wait } from 'node:timers/promises';

export default async function ({ screen, expect }) {
  await expect(screen.getByRole('button', { name: /^Products/ })).toBeVisible();
  await screen.swipe('up');
  await wait(5_000);
}
```

`device`, `screen`, and `expect` come from [Mobilewright](https://github.com/mobile-next/mobilewright);
`packageName` is read from the APK and `sessionDirectory` is the absolute private
output directory. `serial` is the owned ADB transport serial, whereas `device.id`
is the unique AVD name on Linux or that same TCP serial on macOS.
The runner owns device connection and cleanup; do not launch
another device or call `process.exit()`. Await all actions. Throw an error or
let an assertion fail to mark the run failed. You do not need to import
Mobilewright in executor files; the context avoids module-resolution problems
for files outside this repository. Other imports use normal Node resolution
relative to your executor. This is not the Mobilewright/Playwright test-runner
format (`test(...)`); TypeScript compilation and test-runner fixtures are not
included in this experiment.

Scenario stdout/stderr go to `scenario.log` beside the report. Exit status is 0
on completion, 1 on failure/timeout, and 130 on interruption. Failures after the
session starts still print a partial report, whose status and diagnostics show
the failure; input/dependency preflight errors occur before creating a session.
The Node process group and its mobilecli children are stopped before emulator
and proxy cleanup. Each run uses a private `MOBILECLI_HOME`, an owned foreground
daemon and a separate mobilecli WebSocket port, not its shared default daemon
or server. Like manual captures, pending network responses may be incomplete
at shutdown, and a successful scenario does not imply all HTTP responses succeeded.

Both environments provide Node.js 24; Mobilewright requires Node >=22.12. The
runtime lives in the immutable Nix store, not in the checkout. Re-enter devenv
after editing the runner or its dependency manifests to select the rebuilt
runtime. No packages are downloaded or installed by `--scenario` itself.
Native Android verification requires the same supported emulator host as manual
mode. WebView DOM APIs additionally need a debuggable WebView; the sample uses
native accessibility for cross-origin consent buttons because Mobilewright
0.0.64 does not implement `frameLocator`.

Mobilecli 1.0.18's injected Android in-app agent is ARM64-only: its
[build selects AArch64](https://github.com/mobile-next/mobilecli/blob/1.0.18/agents/android/Makefile#L17-L23),
and its [installer uses one embedded library without ABI selection](https://github.com/mobile-next/mobilecli/blob/1.0.18/devices/android_webview.go#L144-L169).
On the x86_64 emulator, injection fails with `EM_AARCH64 (183) instead of
EM_X86_64 (62)`. Features needing that helper, including WebView Page attachment,
are unavailable there; native accessibility actions can still work. The sample
does not build a custom helper or fork Mobilecli to bypass this limitation.

Mobilecli's Flutter VM render-tree mode does not merge WebView accessibility
nodes and can expose offscreen Flutter widgets as actionable. On macOS the runner
therefore reads Mobilecli's raw Android DeviceServer hierarchy for every native
locator, preserving WebView children, accessibility labels and resource IDs.
Use those native selectors rather than Flutter-only widget keys on macOS.
The adapter reuses the run's private Mobilecli daemon and fails explicitly if
the native JSON hierarchy is unavailable; it does not fall back to Flutter or
hard-coded coordinate taps. Linux keeps Mobilewright's default driver.

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
- `scenario.log` (automated runs): scenario progress, assertion failures and
  Mobilewright errors. The resolved TOML `scenario` path, JavaScript `executor`
  path and timeout are in `session.json`.

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

Both test commands exercise real Node subprocess failures and
timeout/process-group cleanup using the Nix-built runtime, without a device.
The flake also checks scenario preflight through its installed CLI with an
empty caller environment, outside the source tree.
Audit lifecycle tests use real mitmproxy/report IO with Android and scenario
outcomes substituted; they are not native UI verification.

The tests use real mitmdump and local HTTP/TLS servers. They check hostname
boundaries, compressed responses, repeated headers, binary POSTs, upstream
disconnects, truncation versus full raw flows, safe HTML, and CONNECT-to-IP with
hostname SNI and trusted certificates (the emulator's proxy transport). Host
preflight tests cover macOS without KVM, Linux with/without KVM, unsupported
hosts, missing system images and unavailable hardware acceleration.

Native acceptance: run
`network-audit sample-app --domain '*.bunte.de' --domain dummyjson.com`, verify ten
successful `dummyjson.com/products/<1..10>` responses, open BUNTE and inspect its responses,
press Home, then confirm the report appears and the owned emulator/proxy exit.
Run once more and finish with Ctrl+C to check the alternate stop path.

CA installation follows the temporary mount-namespace approach described in
[Android 14 CA injection](https://httptoolkit.com/blog/android-14-install-system-ca-certificate/).
