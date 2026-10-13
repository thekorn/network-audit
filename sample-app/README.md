# network_audit_sample

A Flutter sample for comparing native Dart and WebView traffic. Native UI and
product capture have been verified on Android and iOS Simulator; shared WebKit
helper traffic is outside the iOS backend's capture scope.

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
ten product responses in both the UI and the network capture. It deliberately
does not test BUNTE: shared WebKit helper traffic is outside the iOS backend's
process-path capture scope. See [iOS requirements and limits](../network-audit/README.md#experimental-ios-simulator-backend).
Builds, product capture and recording have been verified on Apple Silicon with
iOS 27 Simulator. The shared `browse.toml` scenario also completed, including
native-accessibility consent acceptance inside BUNTE's WebView. Its Android
dimensions are ignored with a warning on iOS. The Linux runner cannot perform
these iOS checks; a Mac with full Xcode is required.

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
