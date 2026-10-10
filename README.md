# network-audit

Capture Android HTTP(S) traffic with mitmproxy and generate an offline HTML report.
Built with Nix and [devenv](https://devenv.sh).
The [sample app](sample-app/README.md) has a native DummyJSON product feed that
sends ten GET requests per batch and an Android WebView loading BUNTE.

## Install or run with Nix

On **x86_64 Linux with readable/writable `/dev/kvm`** or **Apple Silicon macOS**,
the flake bundles the CLI, Python/Jinja2, mitmproxy, OpenSSL, Flutter, JDK and
the Android SDK with its rootable API 36 Google APIs emulator image. No clone,
devenv installation, Android Studio or manual SDK setup is required. Nix must
have `nix-command` and `flakes` enabled (`experimental-features = nix-command
flakes` in your Nix configuration). Intel Macs and ARM Linux are not supported.

**The full package is a multi-gigabyte toolchain download. Using it assumes you
accept the [Android SDK license](https://developer.android.com/studio/terms);
the flake permits the required unfree SDK packages and accepts that license
declaratively. Do not build or run the full package inside an Amp orb.**

The emulator also needs over 12 GiB of free temporary-disk space for its
disposable AVD; leave additional room for Flutter/Gradle caches and builds.
Set `TMPDIR` to a writable directory on a larger volume if necessary.

Run without installing, passing either an APK or a Flutter project with a
committed `pubspec.lock`:

```bash
nix run github:thekorn/network-audit -- /path/to/app.apk --domain api.example.com
nix run github:thekorn/network-audit -- /path/to/flutter-project --domain api.example.com
```

Or install the `network-audit` command into your Nix profile:

```bash
nix profile add github:thekorn/network-audit
network-audit /path/to/app.apk --domain api.example.com
```

`packages.default` / `packages.network-audit` and the corresponding `apps`
outputs provide the same full package. To pin a particular source revision,
use `github:thekorn/network-audit/<commit>` instead. In a checkout, `nix run . --
...` and `nix build .` use the local flake. A profile install does not install the
sample app; clone this repository if you want to audit `sample-app`.

The wrapper selects its own pinned SDK and tools without changing your shell.
Flutter/Gradle use their usual writable user caches (or your `PUB_CACHE` and
`GRADLE_USER_HOME` overrides); application dependencies still need downloading
on the first build. Reports are written relative to your current directory,
not to the Nix store. Domain configuration and all other CLI options work as
described in [tool usage](network-audit/README.md).

For regenerating reports without Flutter, Java, an SDK or an emulator image:

```bash
nix run github:thekorn/network-audit#network-audit-core -- report /path/to/session
```

This smaller package includes Python/Jinja2, mitmproxy and OpenSSL. Auditing with
it requires an externally supplied compatible Flutter/Android environment;
most users should use the default package. It is safe to build and use for
report generation in an orb.

## Audit the sample

On an **Apple Silicon Mac** or **KVM-capable x86_64 Linux host** (not in an Amp
orb), run the foreground audit command from the repository root:

```bash
devenv shell audit sample-app
```

This enables the emulator for this run only and forwards all arguments to
`network-audit`. The app can be a Flutter project directory or an Android APK.
Quote paths containing spaces, for example `devenv shell audit '../my app'`.
CLI options also work: `devenv shell audit sample-app --headless`.

Press **Ctrl+C once** in the terminal to finish the capture, then wait for the
printed report path. Output streams directly, with no task TUI or confirmation
prompt. This replaces `devenv tasks run network-audit --input app=sample-app`:
the foreground command avoids devenv 2.4.0's five-second task shutdown deadline,
allowing emulator/proxy cleanup and report generation to finish.

Alternatively, enable the declared emulator in the ignored `devenv.local.nix`:

```nix
{ androidEmulator.enable = true; }
```

Then run from the repository root:

```bash
devenv shell
network-audit sample-app
```

Or enable the emulator for a single command:

```bash
devenv shell -O androidEmulator.enable:bool true -- network-audit sample-app
```

On Linux without `DISPLAY` (such as an SSH session), the CLI automatically runs
headless and prints a notice. Use ADB to interact and Ctrl+C to finish; for an
emulator window, run from a graphical session with a working X11/XWayland
`DISPLAY`. `--headless` explicitly hides the window on either supported host.

On macOS, use native ARM64 Nix/devenv, not Rosetta. The environment selects the
ARM64 Android image and the emulator uses macOS's built-in Hypervisor.Framework;
Linux uses the x86_64 image and KVM. Intel Macs are not supported by the pinned
Nix Flutter/Android packages. Android Studio is not required.
The CLI checks the declared image and hardware acceleration before building.

The command builds the debug APK, creates and boots a disposable Android 36 AVD,
installs a session-only system CA (including Android's Conscrypt trust store),
and launches the app. No manual AVD or certificate setup is needed. Requests and
responses matching `*.bunte.de` and `dummyjson.com` print as they happen. Visit
both app tabs, then close/leave the app for five seconds or press Ctrl+C.
The emulator and proxy stop and the command prints the HTML report path.

Reports contain searchable exchanges, request/response headers and body previews,
host counts, durations, HTTP errors, incomplete requests and TLS diagnostics.
All data stays in the private, ignored `.network-audit/runs/<session>/` directory.
**Cookies, tokens and bodies are not redacted. Review before sharing.**

See [tool usage, configuration, limits and tests](network-audit/README.md).

## Toolchain

`flake.lock` pins the distribution's nixpkgs input; `devenv.lock` pins nixpkgs
and devenv modules for development. Both initially select the same nixpkgs
revision, and `nix/toolchain.nix` shares the SDK versions and environment between
them. The current environment provides
Flutter 3.47.7 stable (Dart 3.13.5), devenv 2.4.0, JDK 17, Android API 36,
build-tools 36.0.0, NDK 28.2.13676358, CMake 3.22.1, `adb`, `sdkmanager`, and
`avdmanager`. These Android versions match the Flutter starter project's requirements.
Android SDK licenses are accepted declaratively; entering the environment assumes
you accept the [Android SDK license](https://developer.android.com/studio/terms).
Flutter analytics are disabled.

Flutter 3.47.7 is the latest stable release verified on 2026-10-10. Because nixpkgs
still packages 3.47.4, `nix/flutter.nix` uses the standard nixpkgs Flutter builder
and wrappers with generated, hash-pinned 3.47.7 metadata. See
[the override maintenance notes](nix/README.md). This adds a one-time build on a
cold machine; warm orbs reuse it rather than rebuilding or upgrading Flutter.

Install [Nix and devenv](https://devenv.sh/getting-started/) on your development
machine, then:

```bash
devenv shell
flutter --version
devenv test
```

`devenv test` shows a named result for toolchain and Android SDK checks, Pyright,
Python tests, Flutter analysis, and Flutter tests. Successful analysis output and
test totals are shown without `--verbose`; failed checks include their diagnostics.
All checks run even if another check fails, and any failure makes the command exit
nonzero. Flutter commands run sequentially to avoid startup-lock contention.

Use `devenv shell <command>` for noninteractive commands. Flutter and its bundled
Dart come from the same Nix package; do not run `flutter upgrade`, `sdkmanager
--install`, or try to write into `/nix/store`. Change the declared versions and
update the lockfile instead. Pub and Gradle caches live under `.devenv/state/`.

To deliberately update the toolchain, run `devenv update` and `nix flake update
nixpkgs`, review both lockfiles and keep their nixpkgs revisions aligned,
update or remove the Flutter override as described in `nix/README.md`, check
Flutter's Android defaults against `nix/toolchain.nix`, and run `devenv test`,
`nix flake check` plus an Android APK build. Updating nixpkgs also updates the
devenv CLI installed by orb setup; keep its version compatible with the modules
pinned in `devenv.yaml`.

`nix flake check` builds the core package, runs the Python tests (including real
local HTTP/TLS proxy traffic), and tests the installed command and report
template in a clean environment outside the source tree. It does **not**
download emulator images or test a running Android device. Use `nix flake check
--all-systems --no-build` to evaluate both supported platforms; build and run
the default package on each native host for full acceptance testing.

## Amp orbs: build and test, not Android emulation

**Amp orbs have no KVM. They cannot run the Android emulator in this setup.**
Use an Apple Silicon Mac or KVM-capable Linux development machine for an emulator.
Amp agents working in orbs use the `thekorn-amp-runner` runner for native emulator
verification. Agents on Apple Silicon Macs may run the emulator directly.
A browser/mobile viewport is not an Android emulator.

`.agents/setup` installs checksum-verified Nix 2.35.2 in single-user mode (no
daemon), installs devenv from the locked nixpkgs revision, and realizes the full
Flutter/Android build environment. It also runs `flutter pub get --enforce-lockfile`
using `sample-app/pubspec.yaml` and its committed `pubspec.lock`. It never
updates lockfiles automatically, installs emulator images, creates AVDs, or
starts servers. The orb's single-user Nix disables build sandboxing inside the
already isolated orb; this is not configuration for a shared Nix machine.

Amp can snapshot the Nix store, devenv environment and dependency caches after a
successful setup, so later orbs reuse them. Exact snapshots skip setup; repeated
setup on a warm filesystem converges without reinstalling the packages.
The first cold setup still needs to download the SDKs. Gradle/Maven dependencies
are application-specific and are downloaded on the first APK build.

A repository-scoped, guarded Bash login hook exports the **whole** devenv
environment into new Amp shells and future supervised service shells, including
SDK paths, Java, Pub and Gradle settings. It also works in repository
subdirectories without nesting `devenv shell`. `.agents/resume` only checks that
Nix and devenv are still available and performs no downloads or authentication.

To verify or repair this orb manually:

```bash
.agents/setup
.agents/resume
devenv test
```

The Android sample needs no app server. If one is added, declare it in
`.amp/services.yaml` and use `amp orb services ensure`; do not start long-lived
services from setup or resume. Do not commit credentials, ADB pairing keys,
generated APKs, or local environment state.

The setup files must reach the Amp project's **default branch** before fresh
orbs use them. A local commit alone does not activate setup for future orbs.

## Run a Flutter app on an Android emulator (outside an orb)

The optional emulator configuration targets **Apple Silicon macOS** or
**x86_64 Linux with accessible `/dev/kvm`**. It is not enabled automatically and
must not be enabled inside orbs. On a supported host, create the ignored
`devenv.local.nix`:

```nix
{
  androidEmulator.enable = true;
}
```

Enter `devenv shell`, verify hardware acceleration, and create the AVD once:

```bash
emulator -accel-check
avdmanager create avd --name network-audit \
  --package "$NETWORK_AUDIT_SYSTEM_IMAGE"
emulator -avd network-audit
```

In a second devenv shell, run the sample app:

```bash
cd sample-app
flutter pub get --enforce-lockfile
flutter devices
flutter run -d <device-id>
```

From `sample-app`, build without a device using `flutter build apk --debug`;
run static checks with `flutter analyze` and unit/widget tests with `flutter test`.
In an Amp orb, use `thekorn-amp-runner` for native emulator verification; on an
Apple Silicon Mac, the emulator can run directly.
