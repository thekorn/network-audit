{
  config,
  inputs,
  lib,
  pkgs,
  ...
}:

let
  flutter = import ./nix/flutter.nix { inherit pkgs; };
  python = pkgs.python3.withPackages (ps: [ ps.jinja2 ]);
  buildToolsVersion = "36.0.0";
  ndkVersion = "28.2.13676358";
  emulatorAbi = if pkgs.stdenv.hostPlatform.isAarch64 then "arm64-v8a" else "x86_64";
  # Compose the SDK directly: devenv's Android module also adds an emulator
  # helper even when android.emulator.enable is false.
  androidEnv = pkgs.callPackage "${pkgs.path}/pkgs/development/mobile/androidenv" {
    licenseAccepted = true;
  };
  android = androidEnv.composeAndroidPackages {
    platformVersions = [ "36" ];
    buildToolsVersions = [ buildToolsVersion ];
    includeNDK = true;
    ndkVersions = [ ndkVersion ];
    cmakeVersions = [ "3.22.1" ];
    includeSources = false;
    includeEmulator = config.androidEmulator.enable;
    includeSystemImages = config.androidEmulator.enable;
    systemImageTypes = [ "google_apis" ];
    abiVersions = [ emulatorAbi ];
  };
  androidHome = "${android.androidsdk}/libexec/android-sdk";
in
{
  options.androidEmulator.enable = lib.mkEnableOption "the Android emulator and host-native API 36 image (Apple Silicon Macs or KVM-capable x86_64 Linux hosts, never orbs)";

  config = {
    # v2.4.0's generated latest-version file still says 2.3.1. Use the pinned
    # release's actual version, retaining warnings for real CLI mismatches.
    devenv.latestVersion =
      (builtins.fromTOML (builtins.readFile "${inputs.devenv}/Cargo.toml")).workspace.package.version;

    packages = [
      flutter
      pkgs.jdk17
      android.androidsdk
      android.platform-tools
      python
      pkgs.mitmproxy
      pkgs.pyright
      pkgs.openssl
    ];

    scripts.network-audit.exec = ''
      exec ${python}/bin/python3 ${lib.escapeShellArg "${config.devenv.root}/network-audit/cli.py"} "$@"
    '';

    env = {
      DEVENV_TOOLBOX = "network-audit";
      ANDROID_HOME = androidHome;
      ANDROID_SDK_ROOT = androidHome;
      ANDROID_NDK_ROOT = "${androidHome}/ndk/${ndkVersion}";
      JAVA_HOME = pkgs.jdk17.home;
      FLUTTER_ROOT = "${flutter}";
      GRADLE_OPTS = "-Dorg.gradle.project.android.aapt2FromMavenOverride=${androidHome}/build-tools/${buildToolsVersion}/aapt2";
      PUB_CACHE = "${config.devenv.state}/pub-cache";
      GRADLE_USER_HOME = "${config.devenv.state}/gradle";
      NETWORK_AUDIT_DEVENV = config.devenv.root;
      NETWORK_AUDIT_SYSTEM_IMAGE = "system-images;android-36;google_apis;${emulatorAbi}";
      FLUTTER_SUPPRESS_ANALYTICS = "true";
    };

    enterTest = ''
      set -euo pipefail
      flutter --version
      dart --version
      java -version
      adb version
      mitmdump --version
      network-audit --help
      pyright
      python3 -m unittest discover -s network-audit/tests -v
      test -f "$ANDROID_HOME/platforms/android-36/android.jar"
      test -x "$ANDROID_HOME/build-tools/${buildToolsVersion}/aapt2"
      test -f "$ANDROID_NDK_ROOT/source.properties"
      test -d "$ANDROID_HOME/cmake/3.22.1"
      ${lib.optionalString config.androidEmulator.enable ''
        test -x "$ANDROID_HOME/emulator/emulator"
        test -f "$ANDROID_HOME/system-images/android-36/google_apis/${emulatorAbi}/package.xml"
      ''}
    '';
  };
}
