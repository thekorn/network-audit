# network_audit_sample

A Flutter sample for comparing native Dart and WebView traffic. Native UI,
product capture and BUNTE WebView HTTP(S) capture have been verified on Android
and iOS 27 Simulator. iOS WebKit capture requires iOS 17+ and library injection.

- **Products:** opening the app sends ten separate, concurrent GET requests to
  `https://dummyjson.com/products/1` through `/10`. The feed shows product images,
  prices, and a success/failure count. Pull to refresh or tap **Run 10 GETs again**
  for another batch. Batches cannot overlap. Each request has a 20-second timeout;
  failures remain visible alongside successful products, with no automatic retry.
- **BUNTE:** uses Flutter's official `webview_flutter` package to load
  `https://www.bunte.de` with JavaScript enabled. Back, home, and reload controls
  are above the page. The website may show its own consent or subscription prompt.

The WebView starts only when first selected. Switching tabs preserves the feed,
scroll position, and website state without deliberately triggering another load.
Images produce additional requests and can be cached by Flutter. The ten product
API calls are not cached by the app. Website traffic is controlled by BUNTE, not
by the ten-request batch. HTTP(S) navigation stays in the WebView; external app
schemes are not opened. No accounts, API keys, or backend are needed.

## Run with devenv

From the repository root, enter `devenv shell`, then:

```bash
cd sample-app
flutter pub get --enforce-lockfile
flutter run -d <android-device-id>
```

The app targets Android and iOS, not Flutter web. Use a real device or a KVM-capable host
for an Android emulator; Amp orbs can build and test but cannot run an emulator.
The configured Amp emulator runner is `thekorn-amp-runner`.

For iOS Simulator on a Mac with full Xcode and an installed iOS runtime:

```bash
devenv shell audit sample-app --backend=ios --scenario sample-app/scenarios/products-ios.toml
```

Run that command from the repository root. This experimental scenario checks the
ten product responses in both the UI and the network capture. For BUNTE, replace
`products-ios.toml` with `browse.toml`. On iOS 17+, the audit injects a launch-only
helper that configures the app's WebKit proxy before navigation, without changing
app source or the bundle. See [iOS requirements and limits](../network-audit/README.md#experimental-ios-simulator-backend).
Builds, product capture and recording have been verified on Apple Silicon with
iOS 27 Simulator. The shared `browse.toml` scenario also completed with BUNTE,
consent and advertising HTTP(S) requests in the capture. Its Android
dimensions are ignored with a warning on iOS. The Linux runner cannot perform
these iOS checks; a Mac with full Xcode is required.

## WebView audit gate

`scenarios/browse.toml` uses `browse.env.json` to set the compile-time Dart define
`NETWORK_AUDIT_WEBVIEW_GATE=true`. The gate applies to Android and iOS debug builds:
selecting BUNTE initially loads `about:blank`, not the website. The shared scenario
then calls `captureWebViewAds({ navigateTo: 'https://www.bunte.de', waitForGate: true })`
before accepting consent. The helper waits for the blank page's readiness marker,
requires the blank target, and installs the message bridge
and document-start observer before navigating, so the observer is ready before
the first BUNTE page JavaScript runs. The runner cleans up the capture automatically.
Android uses CDP; iOS 17+ uses a WKUserScript and script-message handler in the
app-scoped WebKit helper. Both use native accessibility for browsing and consent.

`ad-events.jsonl` retains the selected ad observations independently of the HTTP
domain filter. The report shows placement mappings, auctions, bidder observations,
prices, IDs, win/render evidence, snapshot history and coverage gaps. It does not
claim complete advertising visibility: see [WebView ad evidence](../network-audit/README.md#webview-ad-evidence-android-and-ios).

Android enables WebView debugging explicitly only when the application is
debuggable. No extra Dart plugin is needed. Normal builds without the define,
and release/profile builds on both platforms, retain immediate BUNTE loading
when the tab is selected. Existing navigation controls and tab state are unchanged.

If you manually run a gated Android or iOS debug build (for example,
`flutter run --dart-define=NETWORK_AUDIT_WEBVIEW_GATE=true`), BUNTE stays blank until
the runner navigates it. Reloading the blank page does not open BUNTE. The existing
**BUNTE home** button can open the website manually, but doing so bypasses the
observer-before-navigation guarantee; restart the app before running the audit.
CLI `--dart-define-from-file` options replace the scenario's env-file default, so
any replacement file used for this scenario must retain the gate define.

## Check and build

Run `devenv test` from the repository root. In `sample-app`, inside that environment:

```bash
flutter analyze
flutter test
flutter build apk --debug
```

The debug APK is `build/app/outputs/flutter-apk/app-debug.apk`. The HTTP tests use
a local server; they do not depend on DummyJSON availability. Native verification
of the WebView requires a running Android device or iOS Simulator with Internet access.
