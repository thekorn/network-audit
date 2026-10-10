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

To use a Flutter version managed by [FVM](https://fvm.app), install FVM on your
PATH and configure the project's SDK with `fvm use <version>`, then run:

```sh
network-audit /path/to/flutter-project --use-fvm --domain api.example.com
```

`--use-fvm` runs both `fvm flutter pub get --enforce-lockfile` and
`fvm flutter build apk --debug --no-pub` from the project directory, so FVM
selects the SDK. Without the flag, the CLI uses `flutter` as before. FVM is not
bundled with network-audit; a missing `fvm` executable produces an error rather
than falling back to `flutter`. The flag is ignored for prebuilt APKs, which
require neither Flutter nor FVM. The Android SDK and emulator remain unchanged.
The bundled Android SDK includes platforms 34, 35 and 36 plus build-tools 35.0.0
and 36.0.0. FVM does not add other Android SDK components: if a project requires
another version, it must be declared in the Nix toolchain, not installed into
the read-only `/nix/store` by Gradle or `sdkmanager`.

### Flutter environment values

Pass Flutter's `--dart-define-from-file` option to bake configuration into the
debug APK before it runs in the emulator:

```sh
network-audit /path/to/flutter-project --domain api.example.com \
  --dart-define-from-file /path/to/config/dev.json
# The devenv shortcut forwards the same option:
devenv shell audit /path/to/flutter-project --domain api.example.com \
  --dart-define-from-file /path/to/config/dev.json
```

For example, `dev.json` can contain:

```json
{
  "API_URL": "https://api.example.com",
  "ENABLE_DEBUG_MENU": true
}
```

Read these as compile-time values in Dart, not process environment variables:

```dart
const apiUrl = String.fromEnvironment('API_URL');
const enableDebugMenu = bool.fromEnvironment('ENABLE_DEBUG_MENU');
```

JSON and `.env` files are parsed by Flutter. Relative paths resolve from the
directory where you invoke `network-audit`, **not** from the Flutter project
directory. Repeat the option to layer files (later files override earlier keys),
or use Flutter's comma-separated path syntax. Paths containing spaces work when
quoted; commas separate paths and cannot be part of a filename. The option also
works with `--use-fvm` and `--scenario`. Missing files or directory paths fail
before the build; malformed file contents fail in Flutter before an emulator
session starts. Prebuilt APKs reject the option because their compiled values
cannot be changed.

For scenario runs, set an optional `env-file` instead of passing the flag:

```toml
executor = "browse.mjs"
domains = ["api.example.com"]
env-file = "../config/dev.json"
```

`env-file` names one JSON or `.env` file. Relative paths resolve beside the
scenario TOML, like `executor`; absolute paths also work. Explicit
`--dart-define-from-file` options **replace** this default rather than layering
onto it. Only the selected files must exist, so a CLI override can replace a
scenario default that is absent locally. The `env-file` field must still be a
non-blank string even when overridden. This is the same Flutter compile-time
configuration, not environment variables for the JavaScript executor; it also
requires a Flutter project rather than a prebuilt APK.

Keep private configuration files out of version control. These values are
embedded in the APK, so do not treat Dart defines as secret storage.

### Android runtime

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
dimensions = { width = 1280, height = 2856, density = 480 }
```

Select it with `--scenario sample-app/scenarios/browse.toml`. Before checking the
runtime, building the app or creating a session, the CLI validates the parsed
TOML against the bundled [JSON Schema](scenario.schema.json). `executor` is
required and must name a trusted JavaScript file (`.js` or `.mjs`). `domains` is
optional; when present, it must be a non-empty list of hostnames. The optional
`env-file` selects [Flutter environment values](#flutter-environment-values).
Unknown fields are rejected so a typo cannot silently turn off filtering.

The optional `dimensions` sets the disposable emulator's display **before boot**,
so both the app and executor start with the requested size. `width` and `height`
are pixels, and `density` is dpi. All three are required positive integers;
the emulator requires an even width. Omit `dimensions` to keep the emulator
defaults. It works with both windowed and `--headless` runs and does not change
any existing AVD. A regular TOML table is equivalent to the inline form above:

```toml
executor = "browse.mjs"

[dimensions]
width = 1280
height = 2856
density = 480
```

To capture all HTTP(S) requests reaching the proxy, omit `domains` entirely:

```toml
executor = "browse.mjs"
```

This includes traffic from the whole dedicated emulator, not only the audited
app. Explicit `domains = []` is invalid. The TOML path is relative to your
current working directory; a relative executor path resolves beside the TOML
file, not beside the app or relative to the working directory. Absolute executor
paths also work. Different scenarios can share an executor but log different domains.

The CLI no longer discovers `network-audit.toml` in the app directory or beside
an APK, and `--scenario` no longer accepts a JavaScript file directly. To migrate,
move the old `domains` list into each scenario's TOML and add its `executor` path.
For manual captures without a scenario, specify domains with `--domain`.

`--domain` may be repeated and **replaces** the scenario's domain filter, including
when `domains` is omitted. The TOML must still pass validation even when a CLI
override is supplied. Exact names match
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

### Record an audit video

Add `--record` to save a silent MP4 of the emulator screen beside the report:

```sh
network-audit /path/to/app.apk --domain api.example.com --record
network-audit sample-app --headless --scenario sample-app/scenarios/browse.toml --record
# The devenv shortcut forwards the flag too:
devenv shell audit sample-app --domain dummyjson.com --record
```

Recording starts before APK installation and app launch, after emulator boot
and CA setup. It stops and saves `recording.mp4` before emulator shutdown on
normal completion, Ctrl+C, SIGTERM, or a handled audit/scenario failure. The
CLI prints `Video: <path>` when the recording was saved. `--output` moves the
video along with the other session files. Without `--record`, no video is made.

This uses the declared API 36 image's `screenrecord --time-limit 0`, so there is
no three-minute time limit and no additional host dependency. It captures the
whole display, not audio or the host's emulator window, and works headless.
Android chooses the recording resolution/encoding at startup. Video consumes
additional device and host disk space.

A recording failure fails the command rather than silently claiming a complete
video; network reports are still generated. See `recording.log` and session
diagnostics. Failed transfers can leave `recording.mp4.partial`. Finish with
Ctrl+C or leave the app instead of killing/closing the emulator: a device crash,
SIGKILL, or host power loss can prevent video finalization or recovery.
**Screen contents are not redacted; review the video before sharing.**

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
  request paths and decoded query parameters as key/value pairs, expandable
  request/response headers, trailers, text or base64 bodies, status, timing,
  wire sizes and diagnostics. Paths retain their URL encoding; query parameters
  preserve order, duplicate keys and empty values. Untrusted content is escaped
  and rendered as text, never as HTML. Binary content is not executed or embedded.
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
- `recording.mp4`, `recording.log` (`--record`): silent emulator video and recorder
  diagnostics. Successful saves add `recording` to `session.json`; recording
  cleanup errors are kept separately as `recording_failure`, so an original
  audit/scenario failure is not lost.
- `scenario.log` (automated runs): scenario progress, assertion failures and
  Mobilewright errors. The resolved TOML `scenario` path, JavaScript `executor`
  path and timeout are in `session.json`. Its `domains` value is `null` for
  unfiltered captures, otherwise the effective hostname list after CLI overrides.

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
Recording tests exercise graceful process signaling, transfer completion,
opt-in behavior and report preservation through a substituted ADB/device
boundary; they do not verify native MP4 encoding or playback.

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
