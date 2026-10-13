# Flutter release override

`flutter.json` is generated metadata for Flutter **3.47.7 stable**, Dart
**3.13.5**, released 2026-10-08. The current nixpkgs input only packages Flutter
3.47.4. `flutter.nix` keeps nixpkgs' normal builder, patches, precached engine
artifacts and runtime wrappers while selecting the newer release.

It also backports Flutter's [copied-framework permission fix](https://github.com/flutter/flutter/commit/92041655586094519e44bc471b3700765b81c8c8).
macOS 15.4+ `openrsync` ignores Flutter's `--chmod` option, so frameworks copied
from the Nix store remain read-only and `lipo` cannot create `Flutter.lipo`.
The upstream patch makes only the copied build-output frameworks writable;
the SDK remains immutable. Passing the patch through `mkFlutter` also rebuilds
the tool snapshot, rather than changing unused Dart source alone.

The metadata was generated, not hand-edited, using the updater from the exact
nixpkgs revision pinned in `devenv.lock`:

```text
pkgs/development/compilers/flutter/update/update.py
```

To update it, use a separate writable checkout of that nixpkgs revision, with
Nix and Python plus PyYAML available, and run from that checkout:

```bash
nix-shell -I nixpkgs=. -p python3Packages.pyyaml --run \
  'python3 pkgs/development/compilers/flutter/update/update.py --version 3.47.7 --channel stable'
```

Replace the version deliberately after checking Flutter's official release
manifest at https://storage.googleapis.com/flutter_infra_release/releases/releases_linux.json.
Copy the generated `pkgs/development/compilers/flutter/versions/3_47/data.json`
to this directory as `flutter.json` (the version directory changes across minor
releases). The updater intentionally builds with placeholder hashes, captures
the resulting hash mismatches, and writes the actual hashes. It downloads
artifacts for several platforms and can take minutes and substantial disk space;
it must **not** run during orb setup.

Run `.agents/setup`, `devenv test`, `nix flake check`, and a starter-app `flutter analyze`,
`flutter test`, and `flutter build apk --debug` after an update. Check the SDK,
NDK and build-tools versions too. Do not mistake successful metadata generation
for a successful application build.

When the locked nixpkgs ships the desired release and includes the permission
fix, replace the `flutter` binding in `nix/toolchain.nix` with `pkgs.flutter` and
remove the override and generated metadata. This shared expression supplies
both devenv and the distribution flake; keep the nixpkgs revisions in
`devenv.lock` and `flake.lock` aligned when updating the toolchain.

## Mobilewright runtime

`mobilewright.nix` supplies the same immutable JavaScript runtime to devenv and
both flake packages. `buildNpmPackage` fetches dependencies from the committed
`network-audit/mobilewright/package-lock.json` into a hash-verified npm cache,
then runs `npm ci` offline during the build. Shell entry and installed CLI use
need no manual npm command, writable Nix store, or checkout `node_modules`.

When deliberately updating the npm manifests, update `npmDepsHash` too. Compute
it from the committed lockfile using `prefetch-npm-deps` from the nixpkgs revision
in `flake.lock`, then run `devenv test` and `nix flake check`. Keep the optional
platform packages in the lockfile: Linux and macOS select their own Mobilecli
binary from the same dependency cache. Runtime install checks import the runner
and execute that binary; core package checks exercise scenario preflight with
no caller Node/npm or source checkout. Native Android acceptance is separate.
