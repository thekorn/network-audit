{
  config,
  inputs,
  lib,
  pkgs,
  ...
}:

let
  flutter = import ./nix/flutter.nix { inherit pkgs; };
  buildToolsVersion = "36.0.0";
  ndkVersion = "28.2.13676358";
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
    abiVersions = [ "x86_64" ];
  };
  androidHome = "${android.androidsdk}/libexec/android-sdk";
in
{
  options.androidEmulator.enable = lib.mkEnableOption "the Android emulator and API 36 x86_64 image (KVM-capable Linux hosts only, never orbs)";

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
    ];

    env = {
      ANDROID_HOME = androidHome;
      ANDROID_SDK_ROOT = androidHome;
      ANDROID_NDK_ROOT = "${androidHome}/ndk/${ndkVersion}";
      JAVA_HOME = pkgs.jdk17.home;
      FLUTTER_ROOT = "${flutter}";
      GRADLE_OPTS = "-Dorg.gradle.project.android.aapt2FromMavenOverride=${androidHome}/build-tools/${buildToolsVersion}/aapt2";
      PUB_CACHE = "${config.devenv.state}/pub-cache";
      GRADLE_USER_HOME = "${config.devenv.state}/gradle";
      NETWORK_AUDIT_DEVENV = config.devenv.root;
      FLUTTER_SUPPRESS_ANALYTICS = "true";
    };

    enterTest = ''
      set -euo pipefail
      flutter --version
      dart --version
      java -version
      adb version
      test -f "$ANDROID_HOME/platforms/android-36/android.jar"
      test -x "$ANDROID_HOME/build-tools/${buildToolsVersion}/aapt2"
      test -f "$ANDROID_NDK_ROOT/source.properties"
      test -d "$ANDROID_HOME/cmake/3.22.1"
    '';
  };
}
