# Getting started

network-audit captures HTTP(S) from a disposable Android emulator, or from an experimental iOS Simulator, and writes a private offline report. It builds and launches the app, installs a session-only certificate, and records only the hosts you select. No logging SDK, proxy setup, or existing emulator is required.

The [sample app](sample-app/README.md) is the shortest way to see that. Its **Products** tab sends ten separate GETs to `https://dummyjson.com/products/1` through `/10`. Its **BUNTE** tab loads `https://www.bunte.de` in a WebView. Longer background is in [What does your Android app actually send?](docs/network-audit.md); flags and limits are in the [tool guide](./docs/README.initial.md).

Run the commands below from the repository root. You need [Nix and devenv](https://devenv.sh/getting-started/) with flakes enabled, on an Apple Silicon Mac or on x86_64 Linux with readable and writable `/dev/kvm`. The first run downloads a multi-gigabyte toolchain. Amp orbs can run the checks, but they cannot boot the Android emulator.

## Check the toolchain

```bash
devenv test
```

Runs every check even when one of them fails, and exits 0 only when all of them pass. Each check prints a named result:

| Check | What a pass means |
| --- | --- |
| `test:toolchain` | `flutter`, `dart`, `java`, `adb`, `mitmdump`, `node`, and `network-audit --help` all run |
| `test:android-sdk` | API 34–36 platforms, build-tools, NDK, and CMake are present |
| `test:pyright` | The CLI and its tests type-check |
| `test:python` | Python unit tests pass, including local HTTP/TLS proxy traffic |
| `test:flutter-analyze` | The sample app has no analyzer issues |
| `test:flutter-tests` | The sample app's widget and HTTP tests pass |

Flutter analysis and tests run one after the other. This command does not boot an emulator.

## Audit the sample by hand

```bash
devenv shell audit sample-app --domain '*.bunte.de' --domain dummyjson.com
```

Turns the Android emulator on for this command only, restores the sample's locked dependencies, builds a debug APK, boots a fresh API 36 emulator, trusts a session-only CA, and launches the app. Hosts outside the two `--domain` filters pass through and are not saved. Quote the wildcard so the shell does not expand it.

The terminal prints the session directory and `Capturing: *.bunte.de, dummyjson.com`, then `Booting a disposable Android API 36 emulator…`. Once the app is up it prints the device serial and waits. On launch you should see ten `dummyjson.com` product responses. Open **BUNTE** if you also want that site's traffic. Matching requests print as they happen.

Press **Ctrl+C once**, or leave the app in the background for five seconds. The emulator and proxy stop. The command then prints:

- `Report:` the path to `report.html`. Open it in a browser; it needs no server.
- `Text report:` the path to `report.txt`, followed by the summary itself: one `hostname: count` line per captured host, then `Total requests: N`.
- `Raw flows:` the path to `flows.mitm`, for later inspection with mitmproxy.

Those files, plus `events.jsonl`, `session.json`, `emulator.log`, and `proxy.log`, stay in `.network-audit/runs/<UTC timestamp>-<suffix>/`. A Products-only capture of this filter is the ten `dummyjson.com` product GETs. Image hosts are separate names, so they show up only when a `--domain` matches them. Headers, cookies, tokens, and bodies are kept as captured. Review a session before sharing it.

## Repeat that journey

```bash
devenv shell audit sample-app --scenario sample-app/scenarios/browse.toml
```

Uses the same emulator, capture, and report. The scenario in `sample-app/scenarios/browse.toml` supplies the domains (`*.bunte.de`, `dummyjson.com`, `*.doubleclick.net`) and a JavaScript executor. The terminal prints `Running scenario on <serial>` and the path to `scenario.log`. The executor waits for the first product batch, scrolls, taps **Run 10 GETs again**, opens BUNTE, accepts consent, scrolls the WebView, and waits five seconds. Completion ends the capture.

A completed run exits 0. The text summary lists the selected hosts and a total. A previously verified Android run contained twenty successful product GETs, two per product, plus BUNTE traffic after consent. BUNTE is a live site, so a changed consent dialog can fail the scenario. Failure or timeout exits 1 and still writes a partial report once a session exists. Interrupting with Ctrl+C exits 130.

The Android browse scenario also installs an ad observer before BUNTE's first
page load. It writes `ad-events.jsonl` and adds placement, auction, bidder, price,
ID and win/render evidence to the HTML report. Earlier observations survive
refreshes and report regeneration; late attachment, missing data and capture gaps
remain explicit. See [scope and limits](network-audit/README.md#webview-ad-evidence-android).

`--headless` hides the emulator window. `--record` adds a silent `recording.mp4` and a `Video:` line next to the report paths.

Add `--har` to either manual or scenario runs to also save `session.har`
and print its `HAR:` path. This captures all intercepted HTTP(S) hosts for the
whole session, including hosts outside the domain filters; the existing reports,
terminal output, and raw flows stay filtered. It also enables TLS interception
for those extra hosts, which can affect pinned connections. The HAR is unredacted,
is not truncated by `--body-limit`, and uses additional memory/disk space.
Existing proxy and backend capture limits still apply; see the
[HAR guide](network-audit/README.md#export-the-whole-https-session-as-har).

## Capture the sample on iOS Simulator

```bash
devenv shell audit sample-app --backend=ios --scenario sample-app/scenarios/products-ios.toml
```

On a Mac with full Xcode and an installed iOS Simulator runtime, this boots a disposable Simulator and leaves the Android emulator off. The first run can ask you to approve Mitmproxy Redirector. The scenario waits until the capture contains HTTPS 200 responses for `/products/1` through `/products/10`, then finishes by itself.

The command prints the same `Report`, `Text report`, and `Raw flows` paths. A completed run's summary lists `dummyjson.com`. A verified iOS 27 run captured exactly ten successful product GETs. The scenario stays on the product feed; shared WebKit helper traffic, including the BUNTE WebView, is outside this backend's capture scope. Use the Android browse scenario for that page.

## Rebuild a report from a saved session

```bash
devenv shell -- network-audit report .network-audit/runs/<session>
```

Reads `events.jsonl` and optional `ad-events.jsonl` in that directory, rewrites `report.html` and `report.txt`, and prints the HTML path, `Text report:`, and the host summary. No emulator or proxy starts.

The same regeneration, without the Android SDK, is:

```bash
nix run .#network-audit-core -- report .network-audit/runs/<session>
```

## Run an audit from Nix

```bash
nix run . -- sample-app --domain dummyjson.com
```

From a checkout, this is the manual Android audit with the flake's bundled toolchain. Pass an APK path instead of `sample-app` when you already have a build. `nix run github:thekorn/network-audit -- …` does the same from any directory, using the published flake rather than this checkout.
