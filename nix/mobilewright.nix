{
  lib,
  buildNpmPackage,
  nodejs_24,
}:

buildNpmPackage {
  pname = "network-audit-mobilewright";
  version = (lib.importJSON ../network-audit/mobilewright/package.json).dependencies.mobilewright;
  nodejs = nodejs_24;

  # Local node_modules and npm caches must never become build inputs.
  src = lib.fileset.toSource {
    root = ../network-audit/mobilewright;
    fileset = lib.fileset.unions [
      ../network-audit/mobilewright/package.json
      ../network-audit/mobilewright/package-lock.json
      ../network-audit/mobilewright/runner.mjs
      ../network-audit/mobilewright/native-android-driver.mjs
      ../network-audit/mobilewright/native-ios-driver.mjs
      ../network-audit/mobilewright/ad-capture.mjs
      ../network-audit/mobilewright/ad-observer.mjs
    ];
  };
  npmDepsHash = "sha256-JLrgxB8APR1wB45NQDXS5DbMmoyRQ3rDH/dIwouzfaU=";
  dontNpmBuild = true;

  # npm ci runs in buildNpmPackage's offline dependency hook, not at runtime.
  installPhase = ''
    runHook preInstall
    mkdir -p "$out"
    cp runner.mjs native-android-driver.mjs native-ios-driver.mjs package.json package-lock.json "$out/"
    cp ad-capture.mjs ad-observer.mjs "$out/"
    cp -R node_modules "$out/node_modules"
    runHook postInstall
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    binary=$(env -i HOME="$TMPDIR" ${nodejs_24}/bin/node "$out/runner.mjs" --check)
    case "$binary" in
      "$out"/node_modules/*) ;;
      *) echo "Mobilecli resolved outside the packaged runtime: $binary" >&2; exit 1 ;;
    esac
    env -i HOME="$TMPDIR" "$binary" --version
    runHook postInstallCheck
  '';

  meta = {
    description = "Lockfile-pinned Mobilewright runtime for network-audit";
    platforms = [
      "x86_64-linux"
      "aarch64-darwin"
    ];
  };
}
