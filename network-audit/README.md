# network-audit v1

A Python CLI with a mitmproxy addon and Jinja2 report templates. The pinned
Nix flake or devenv supplies Python, Jinja2, mitmproxy and OpenSSL; no pip install,
Flutter app modification, proxy override or `badCertificateCallback` is needed.

`--backend=android` is the default; existing commands keep using Android.
`--backend=ios` selects the experimental macOS-only backend described below.
The Android workflow in the remaining sections is unchanged except where noted.

## Experimental iOS Simulator backend

**Product capture and recording verified on Apple Silicon with iOS 27 Simulator.**
Neither an Amp orb nor the Linux `thekorn-amp-runner` can build or run iOS Simulator.
The automated Linux tests
exercise CLI selection, platform validation, build arguments, lifecycle,
recording signals, report preservation and scenario routing through substituted
Xcode/device boundaries; native coverage and remaining limits are listed below.

On an Apple Silicon Mac, install full Xcode, accept its license, complete its
first-launch setup and install an iOS Simulator runtime in Xcode Settings.
Select that Xcode with `xcode-select` or `DEVELOPER_DIR`. Command Line Tools alone
are insufficient. Flutter projects also need a Mac Flutter SDK and any native
plugin build tools their project uses (for example CocoaPods). See
[Flutter's iOS setup](https://docs.flutter.dev/platform-integration/ios/setup).
Xcode and Apple's runtime cannot be bundled by Nix.

Use the **core** package with your Mac's existing Flutter/Xcode environment to
avoid downloading the Android emulator and image:

```sh
nix run .#network-audit-core -- /path/to/flutter-project --backend=ios --domain api.example.com
nix run .#network-audit-core -- /path/to/MyApp.app --backend=ios --domain api.example.com
# With devenv, neither command enables the Android emulator:
devenv shell network-audit sample-app --backend=ios --domain dummyjson.com
devenv shell audit sample-app --backend=ios --scenario sample-app/scenarios/products-ios.toml
```

The full package also accepts `--backend=ios`, but still downloads its bundled
Android toolchain. The pinned Flutter wrapper supplies iOS engine artifacts on
Darwin. No lockfile or SDK download is performed by iOS preflight.

The devenv shell disables Nix's macOS-only Apple SDK (`apple.sdk = null`) and
uses a compiler-free shell on macOS so Xcode selects its own compiler and
linker. If an already-open shell reports `unable to find sdk: 'iphonesimulator'`
or a linker error about `-objc_abi_version`, exit it and re-enter devenv from
a normal terminal: an old shell can retain Nix's `DEVELOPER_DIR`, `SDKROOT`
and `LD`.
Verify with `xcrun --sdk iphonesimulator --show-sdk-path`; it should resolve
inside your selected Xcode installation, not `/nix/store`.

The pinned Flutter SDK also backports an upstream permission fix for frameworks
copied from the immutable Nix store. If a previous failed build left a read-only
`Flutter.framework` and Flutter cannot remove it, make only that generated
output writable before retrying: `chmod -R u+w build/ios/Debug-iphonesimulator/Flutter.framework`
from the app directory. Never change permissions inside `/nix/store`.

Input is a Flutter project with its `ios` platform and committed `pubspec.lock`,
or an unpacked **Simulator** `.app` bundle. Device `.app` builds, IPA files and
APKs are rejected. A prebuilt app must support the host's Simulator architecture.
The CLI reads `CFBundleIdentifier` and `CFBundleSupportedPlatforms` from
`Info.plist`; `simctl install` validates compatibility with the selected runtime.
Flutter builds use `flutter build ios --simulator --debug --no-codesign --no-pub`
after locked `pub get`. `--use-fvm`, `--flavor` (an existing Xcode scheme), Dart
define files and scenario defaults work as on Android. The built bundle is
selected from Flutter's reported output, not an assumed `Runner.app` filename.
Build output is printed after the iOS build finishes. Flavors/defines cannot
change a prebuilt `.app`.

By default, preflight selects the newest available iOS runtime with a supported
iPhone, and the first iPhone device type listed by that runtime. To pin both:

```sh
xcrun simctl list runtimes --json
network-audit MyApp.app --backend=ios --domain api.example.com \
  --ios-runtime com.apple.CoreSimulator.SimRuntime.iOS-18-5 \
  --ios-device-type com.apple.CoreSimulator.SimDeviceType.iPhone-16
```

Those identifiers are examples; select identifiers present on your Mac.
`--dimensions` and scenario `dimensions` are ignored with a warning on iOS,
so the same scenario can keep its Android display settings. Values must still
pass normal CLI/schema validation. Simulator sizes belong to device types, not
arbitrary width/height/density settings; use `--ios-device-type` to select one.

### Capture scope and host permissions

Each run creates a new device via `simctl create`, starts mitmproxy, boots that
device, adds a session-only root CA with `simctl keychain <UDID> add-root-cert`,
installs the app and launches it. Only the created UDID is shut down and deleted.
Existing Simulators, host proxy preferences and host CA trust are not changed.
On SIGKILL or host failure, cleanup is not possible; use the UDID in `session.json`
to remove that one orphaned Simulator manually, never `simctl delete all`.

iOS Simulator does not have Android's per-emulator TCP proxy. Instead, this
backend uses [mitmproxy local capture](https://docs.mitmproxy.org/stable/concepts/modes/#local-capture)
with `local:<owned-UDID>/`. In the pinned macOS redirector, selectors match
substrings of full executable paths. This scopes interception to binaries inside
the new Simulator and can catch direct sockets, including Dart clients that
ignore HTTP proxy settings. It never falls back to unrestricted host capture.

**On first use, mitmproxy installs its signed Mitmproxy Redirector app in
`/Applications` and macOS asks you to approve its network/system extension.**
Writing `/Applications` and approving the extension may need an administrator.
The helper remains installed after the audit; stopping the proxy stops this
capture, not the shared helper installation. Complete first-run approval in an
interactive Mac session before using a headless runner. Allow up to two minutes
for proxy readiness. Run only one local-capture audit/tool at a time because the
redirector is shared. The pinned Nix mitmproxy includes the official signed
macOS helper; no new dependency was added for this backend.

**This is not yet capture parity with Android.** Shared WebKit networking
processes, system services and background URLSession helpers can run from the
shared runtime rather than the device directory and are outside this selector.
In particular, the sample's BUNTE WebView is not an iOS capture acceptance test.
No broad `WebKit` selector is used because that could intercept unrelated host
or Simulator traffic. Certificate pinning/custom trust remain unsupported.
There is no iOS UDP/443 firewall rule: QUIC is not forced to fall back to TCP.
The report explicitly displays these scope limits; a zero-exchange report is
never evidence that the app made no requests.

### Finishing, scenarios and recording

Finish a manual iOS session with **Ctrl+C**. Home/backgrounding does not finish
capture: `simctl` does not provide the Android foreground-activity API used by
`--close-grace`, which is ignored on iOS. Simulator shutdown also ends capture.
`--headless` skips opening the Simulator UI but still boots the device.

`--scenario` attaches Mobilewright's iOS driver to the owned UDID without
relaunching the app. The same executor context is available, with `backend`
equal to `ios`, `serial`/`device.id` equal to the UDID, and `packageName` equal to
the bundle identifier. Before launching the app, the audit uses its private
Mobilecli daemon to install and start the Simulator DeviceKit helper. This
avoids Mobilewright 0.0.64's failing missing-agent check and prevents the helper
from backgrounding an already-launched app. Mobilecli downloads its pinned helper
when needed; no real-device provisioning profile is required. Helper preparation
uses the scenario timeout and cleanup. Android-only executor APIs are not
automatically converted; Android `dimensions` settings are ignored with a warning.
Native selectors read DeviceKit accessibility, including embedded WKWebView
controls, rather than Mobilecli's Flutter-only render tree. Flutter-only widget
keys are not available through this native tree.

`--record` uses `simctl io <UDID> recordVideo --codec=h264`. SIGINT finalizes the
silent MP4 before shutdown. Startup waits for simctl's first-frame acknowledgement,
not an MP4 write: the video can remain buffered until stopping. Only a successful
recorder exit and nonempty output produce `recording.mp4`; failures retain
`recording.partial.mp4` when available and still generate the network report.

### Mac acceptance and remaining checks

The sample now includes a generated iOS platform and a product-only scenario:

```sh
devenv shell audit sample-app --backend=ios \
  --scenario sample-app/scenarios/products-ios.toml --record
```

The scenario requires all ten successful product HTTPS responses **in the
capture**, not only a successful UI. This command completed on an Apple Silicon
Mac with iOS 27, capturing exactly ten successful product GETs from one app
launch. The inspected MP4 shows the Products screen with `10 / 10 loaded · 0 failed`.
Manual headless captures with and without recording also completed on Ctrl+C,
with reports preserved and the owned Simulator removed.

The unchanged `browse.toml` scenario also completed on fresh iOS 27 Simulators
in windowed and headless recorded runs: both product batches loaded, BUNTE
consent was dismissed, and execution reached the final WebView swipes and wait.
Each captured twenty successful product GETs; recordings show BUNTE content
after consent. Only the owned Simulator was removed; two unrelated booted
Simulators were preserved. This verifies WebView UI automation, not capture of
shared WebKit helper traffic.

Remaining native checks include prebuilt Simulator `.app` input, scenario timeout,
denied redirector approval, CA trust failures and simulator boot failure.
Investigate WKWebView/helper attribution separately before widening capture.

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

### Flutter flavors

Select an Android product flavor already configured in your Flutter project:

```sh
network-audit /path/to/flutter-project --domain api.example.com --flavor staging
```

For scenario runs, the TOML can provide the default instead:

```toml
executor = "browse.mjs"
flavor = "staging"
```

An explicit `--flavor` **replaces** the scenario's `flavor`. Both require a
non-blank string and a Flutter project; prebuilt APKs reject flavor settings
because they cannot be rebuilt. The scenario field must be valid even when
overridden. Flutter/Gradle validates whether the selected flavor exists.

The selected identifier is forwarded unchanged to `flutter build apk --debug
--no-pub --flavor <identifier>` (or `fvm flutter` with `--use-fvm`), alongside any
Dart define files. The audit installs the matching APK, using Flutter's lowercase
filename convention: `freeStaging` selects `app-freestaging-debug.apk`.

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
The optional `flavor` selects a [Flutter build flavor](#flutter-flavors).
Unknown fields are rejected so a typo cannot silently turn off filtering.

The optional `dimensions` sets the disposable Android emulator's display
**before boot**, so both the app and executor start with the requested size.
`width` and `height` are pixels, and `density` is dpi. All three are required positive integers;
the emulator requires an even width. Dimensions work with both windowed and
`--headless` runs and do not change any existing AVD. On iOS, scenario dimensions
and `--dimensions` are ignored with a warning; select the display with
`--ios-device-type` instead. A regular TOML table is equivalent to the inline
form above:

```toml
executor = "browse.mjs"

[dimensions]
width = 1280
height = 2856
density = 480
```

For a predefined size, use a shortcut instead of a table:

```toml
executor = "browse.mjs"
dimensions = "big"
```

The only shortcut currently supported is `big`, equivalent to
`{ width = 1280, height = 2856, density = 480 }`. Shortcut names are case-sensitive
and must be quoted strings in TOML. Unknown names are rejected.

For either manual or scenario runs, select a shortcut on the command line:

```sh
network-audit /path/to/app.apk --domain api.example.com --dimensions big
network-audit sample-app --scenario sample-app/scenarios/browse.toml --dimensions big
```

`--dimensions` accepts **only shortcut names**, not custom sizes or tables, and
**replaces** the scenario's `dimensions`. The scenario field must still be valid
even when overridden or ignored on iOS. Explicit custom dimensions remain
available in TOML. Omit both the field and the flag to keep the emulator defaults.

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
through without interception unless `--har` is enabled. UDP port 443 is rejected inside this disposable
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

### Export the whole HTTP(S) session as HAR

Add `--har` (no value) to save `session.har` beside the reports:

```sh
network-audit /path/to/app.apk --domain api.example.com --har
devenv shell audit sample-app --scenario sample-app/scenarios/browse.toml --har
```

The HAR includes **every intercepted HTTP(S) host**, ignoring both `--domain`
and scenario domain filters. The terminal, HTML/text reports, `events.jsonl`
and `flows.mitm` still use those filters. `--output` controls the parent directory
for the HAR along with the other session files. Without the flag, no HAR is made
and excluded hosts continue to pass through without interception.

The HAR is finalized on normal completion, Ctrl+C, SIGTERM, or a handled failure,
and the CLI prints `HAR: <path>`. Failed requests and requests still pending at
shutdown are included with an error; an empty session produces an empty HAR.
A failed export fails the command without suppressing the filtered reports or
the original audit failure. SIGKILL, a proxy crash, or forced shutdown can prevent
export; `session.har.partial` may remain. Offline `report` regeneration does not
reconstruct a HAR: excluded traffic is not in the filtered raw capture.

Export uses mitmproxy's HAR 1.2 conversion, without `--body-limit` preview
truncation. Bodies follow its decoded-text/base64 representation, not a byte-exact
packet archive; binary uploads use mitmproxy's text representation. All captured
HTTP flows are retained in memory until shutdown, so this option increases memory
and disk use and is intended for bounded sessions, not large downloads or streams.

**This enables TLS interception for excluded hosts too**, which can break pinned
connections that previously passed through. Existing trust/pinning and backend
limits still apply: no DNS or arbitrary TCP/UDP capture, no traffic that bypasses
the proxy, and no shared WebKit/system helpers on iOS. The HAR can contain secrets
from hosts outside the report filter. Review it separately before sharing.

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
starting with scenario setup, including iOS helper preparation, app launch,
module loading and Mobilewright connection.
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
therefore reads Mobilecli's raw native hierarchy for every native locator:
DeviceServer on Android and DeviceKit AX snapshots on iOS. The adapters preserve
WebView children, accessibility labels and identifiers. iOS AX frames and taps
use logical screen points, without a Retina pixel-scale conversion.
Use those native selectors rather than Flutter-only widget keys on macOS.
The adapters reuse the run's private Mobilecli daemon and fail explicitly if
the native JSON hierarchy is unavailable; they do not fall back to Flutter or
hard-coded coordinate taps. Linux keeps Mobilewright's default driver.

### WebView ad evidence (Android)

The sample's `browse.toml` also records a separate `ad-events.jsonl` ledger and
adds an **Ad evidence** section to the offline report. This uses the app's
debuggable WebView CDP socket directly, not Mobilecli's ABI-specific helper.
Native accessibility still handles consent. No new SDK is added to the website.

Custom executors receive `captureWebViewAds` in their context. Call it once after
creating the WebView; the runner owns final flushing and cleanup. With no options
it attaches to the current document and marks it **late-attach**. For early capture,
create the WebView without loading the site and call:

```js
await captureWebViewAds({ navigateTo: 'https://www.bunte.de', waitForGate: true });
```

`navigateTo` requires `about:blank` and refuses to reload an already loaded site.
`waitForGate` additionally waits for `window.__networkAuditGateReady === true`;
the sample sets that marker after its initial blank page finishes loading. The
sample's scenario env-file enables this Android-debug-only gate. Observer and
binding registration finish before navigation. The helper refuses ambiguous
multiple WebViews and never attaches to another app's process. iOS and manual
runs do not collect this ledger automatically.

The observer copies selected Prebid auction, bidder-request, response, no-bid,
timeout, rejection, win and render fields at callback time. It keeps aliases and
client/server paths, raw/original/bucketed prices, and distinct bidder/GAM IDs.
GPT request/render callbacks and changing STF placement snapshots supply explicit
placement mappings, targeting and refresh history. Records are appended and
synced to disk as they arrive, not buffered until scenario completion. Report
regeneration preserves every record rather than overwriting earlier auctions.

The report opens with a bid-response overview so offered CPMs are not buried in
request/no-bid rows. Requests and no-bid observations normally have null prices;
they are not priced responses. The overview counts response events, not repeated
prices in win/render events or snapshots, and keeps zero CPM distinct from an
unobserved price. Regenerate an existing report to show this overview without
recapturing traffic or changing its ledger.

This is **not a guarantee of every advertising fact**. Only top-level `pbjs`,
GPT and STF are observed; other runtimes, cross-origin frame internals and
server-side auctions may expose less. STF is sampled every 250 ms and at observed
callbacks, so transient states between samples can be missed. Prebid history
recovered after attachment is labeled backfill because retained objects may have
mutated. Page navigation can destroy a context before its final callback reaches
CDP. Disconnects, missing final flushes, sequence gaps and malformed records are
visible, and valid earlier records remain usable after failures or interruption.
No instrumentation is not “no bids”; a timeout is not a terminal outcome; a win
flag is not proof of a viewable or billable impression. The report never chooses
the highest CPM as the served winner or equates a bid CPM with a clearing price.

Ad telemetry is independent of the HTTP domain filter and body preview limit.
It intentionally excludes cookies, consent strings, user IDs, bidder parameters,
creative markup and unrelated page targeting. Selected ad metadata is still
untrusted, private data. HTTP exchanges are not joined to bids without supporting
evidence. The original network capture and text request summary are unchanged.

## Output and safety

### Save state and start another run from it (Android)

Use `--save-state` to keep a cold-device checkpoint beside the report. Use
`--restore-state` with that run's directory (or its `state` subdirectory) to
start an independent run from the saved state:

```sh
# Keep this exact APK for subsequent runs.
network-audit /path/to/app.apk --domain api.example.com --save-state
network-audit /path/to/app.apk --domain api.example.com \
  --restore-state .network-audit/runs/<previous-session> --save-state
```

The second `--save-state` is optional. Without it, the restored working copy is
discarded at the end, just like an ordinary run. The source checkpoint is never
booted or modified, so several runs can start from the same baseline. Each run
has a new report, proxy and session-only CA. Omitting both flags keeps the fresh,
disposable-device behavior. For `--backend=ios`, see the experimental Simulator
checkpoint section below; the formats are not interchangeable.

This saves the virtual device's persisted data: app preferences, databases,
files and disk caches; WebView cookies, localStorage, IndexedDB and disk caches;
and the device storage used by Android permissions and Keystore. It is not a
running-process snapshot: Flutter widget state, memory-only caches, live DOM/JS,
open connections and WebView sessionStorage are not restored. Pending writes
that the app or WebView has not persisted can be lost. Let important writes
finish before ending a run; force-stop and filesystem sync cannot flush arbitrary
application memory. Restoring a cookie does not revive an expired server session.

On completion, Ctrl+C, SIGTERM, or a handled scenario failure after app launch,
the tool stops recording first, force-stops the app, syncs the guest filesystem,
requests Android poweroff and waits for the emulator to exit cleanly. It then
uses the SDK's bundled `qemu-img` to flatten the writable userdata, encryption-key,
cache and optional SD-card disk chains into independent sparse raw images.
The final `state` directory is published only after conversion and checksumming
finish. If the device has already exited, shutdown times out or saving fails,
the command exits unsuccessfully and still writes the report, with a separate
`state_failure` in `session.json`. SIGKILL or host failure cannot guarantee a
checkpoint. A successful save prints `State: <run>/state`.

Restoration requires the **exact APK bytes**, pinned emulator and system-image
identity, host OS/CPU architecture, and matching virtual hardware. Keep a prebuilt
APK: even a rebuilt app from the same source may have different bytes. An omitted
display setting inherits the checkpoint's setting; an explicit conflicting setting
is rejected. The active WebView provider is also checked. Incompatible, missing or
corrupt state is an error, never a silent fresh-device fallback. Moving state from
Linux x86_64 to Apple Silicon, updating the toolchain, or upgrading the app is not
supported by this first format.

`state/manifest.json` records format version, source run, creation time, app and
toolchain identity, hardware, WebView provider, disk sizes and SHA-256 checksums.
Checksums detect corruption; they do not authenticate the source. Restore only
trusted checkpoints. Copy the **whole `state` directory**, retaining sparse files
where your transfer tool supports it; ordinary copies can expand holes. Checkpoints
can consume several GiB and add shutdown/copy time. Restoration checks temporary
storage against the disks' logical sizes plus headroom; `--output` only moves the
saved checkpoint/report, while `TMPDIR` controls the working device's filesystem.

**State is whole-device data, not filtered by `--domain`.** It can contain login
credentials, private files and identifiers not present in the report. The directory
and its files are private, not encrypted. Do not commit or share it with a report
unless you intend to share this additional data. Proxy private keys and live CA
mounts are not reused. Cache entries remain subject to normal expiry/eviction;
restoring them does not guarantee identical network traffic.

### Save state on iOS Simulator (experimental)

The same flags are available with `--backend=ios` on macOS with full Xcode:

```sh
# Keep this exact Simulator .app bundle for subsequent runs.
network-audit /path/to/MyApp.app --backend=ios --domain api.example.com --save-state
network-audit /path/to/MyApp.app --backend=ios --domain api.example.com \
  --restore-state .network-audit/runs/<previous-session> --save-state
```

**Native acceptance is pending.** Linux tests cover checkpoint file integrity,
independent copies, successive generations, lifecycle failures and reports with
substituted CoreSimulator/ditto boundaries. They do not establish that a real
Simulator boots after archive relocation or that Keychain/WebKit data survives.
Do not rely on this format as your only backup.

Saving shuts down the owned Simulator, clones it into a temporary device set,
then copies that dormant set into `state/device-set` using macOS `ditto` to retain
permissions, links, extended attributes and ACLs. The private `state` directory
is published only after checking file contents, modes and link targets. The
manifest records SHA-256 file checksums, app and toolchain identity, and the
saved device UUID. As on Android, failures retain the report and record
`state_failure`; no partially saved checkpoint is published.

Restoring verifies and copies the archive into a temporary set before asking
CoreSimulator to clone a new device into the default set. The archived set is
never opened by CoreSimulator, which can change metadata even while reading.
The restored device has its own UUID, capture session and report, and uses the
already-installed app rather than reinstalling it. Only that working device is
shut down/deleted; the original checkpoint is retained. A restored run can save
its changed state as another checkpoint. Without `--save-state`, changes are
discarded. Ordinary runs without either flag are unchanged.

This requires a small bundled Objective-C helper, compiled into the run's
temporary directory with the selected Xcode clang. It uses the private
CoreSimulator cross-device-set clone API also used by
[idb](https://github.com/facebook/idb/blob/main/FBSimulatorControl/Management/SimulatorSet.swift).
Missing selectors fail rather than falling back to transplanting device folders.
No additional dependency is downloaded, but Xcode updates can break this API.

Restoration requires the same app bundle contents/modes/links, Xcode and
CoreSimulator identity, iOS runtime version/build, device type, macOS version
and CPU architecture. Omitted `--ios-runtime` and `--ios-device-type` inherit
the saved values; explicit incompatible values fail. Keep a prebuilt `.app`:
rebuilding the same source does not guarantee the same bytes. App bundles with
symlinks pointing outside the bundle are rejected. Real iPhones,
cross-platform restores and portability across different Macs are not supported.
Keep the whole `state` directory on a filesystem that preserves macOS metadata;
copying through an archive/transfer tool that drops metadata is unsupported.
Allow several GiB for the saved set, temporary copy and working Simulator.

The intended coverage is persisted app preferences, files, databases, app-group
data, Simulator Keychain and persistent WKWebView storage. Memory-only state,
nonpersistent/private WebViews, live screens and server state are not captured.
Let writes finish before ending capture; shutdown cannot persist arbitrary app
memory. This does not extend the iOS backend's WebKit network-capture coverage.

**Earlier audit CA trust entries remain in the checkpoint.** Each new run adds
a fresh session CA; proxy private keys are never included. We do not reset the
Keychain or edit trust databases because that could destroy application data or
unrelated trust settings. Removing the temporary private key is not certificate
revocation and does not invalidate already-issued certificates. Use checkpoints
only in isolated audit Simulators, not as clean trust baselines. Like Android
checkpoints, they contain sensitive whole-device data outside domain filters.

### Session files

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
- `ad-events.jsonl` (opt-in Android scenarios): append-only WebView ad evidence,
  document/auction identity and coverage diagnostics. Included in regenerated
  HTML reports; older sessions without it show “Not collected”, not “no bids”.
- `flows.mitm`: complete selected HTTP flows for analysis with `mitmweb -r` or
  `mitmdump -r`. Full captured bodies remain here even when previews are limited.
- `session.har` (`--har`): all intercepted HTTP(S) hosts, independent of the
  report filter. Successful saves add `har` to `session.json`; export failures
  add `har_failure` and may leave `session.har.partial`.
- `session.json`, `emulator.log`, `proxy.log`: session state and diagnostics.
  mitmproxy's console warnings and the captured traffic print to the terminal;
  `proxy.log` contains its stderr.
- `recording.mp4`, `recording.log` (`--record`): silent emulator video and recorder
  diagnostics. Successful saves add `recording` to `session.json`; recording
  cleanup errors are kept separately as `recording_failure`, so an original
  audit/scenario failure is not lost.
- `state/` (`--save-state`, Android or experimental iOS): private cold-device checkpoint and
  checksummed manifest. Successful saves add `state_checkpoint` to `session.json`;
  restored runs record `restored_from`. Save failures record `state_failure`.
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
report or state checkpoint; the temporary AVD, CA and proxy are removed/stopped on normal completion,
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
