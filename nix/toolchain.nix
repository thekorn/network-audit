{
  pkgs,
  enableEmulator ? false,
}:

let
  flutter = import ./flutter.nix { inherit pkgs; };
  buildToolsVersion = "36.0.0";
  ndkVersion = "28.2.13676358";
  emulatorAbi = if pkgs.stdenv.hostPlatform.isAarch64 then "arm64-v8a" else "x86_64";
  # Compose directly: devenv's Android module adds an emulator helper even
  # when its emulator option is disabled. Orbs must not realize emulator images.
  androidEnv = pkgs.callPackage "${pkgs.path}/pkgs/development/mobile/androidenv" {
    licenseAccepted = true;
  };
  android = androidEnv.composeAndroidPackages {
    platformVersions = [ "36" ];
    # Plugins can request AGP's older default even when the app uses API 36.
    # Gradle cannot install missing versions into this immutable SDK.
    buildToolsVersions = [
      "35.0.0"
      buildToolsVersion
      "37.0.0"
    ];
    includeNDK = true;
    ndkVersions = [ ndkVersion ];
    cmakeVersions = [ "3.22.1" ];
    includeSources = false;
    includeEmulator = enableEmulator;
    includeSystemImages = enableEmulator;
    systemImageTypes = [ "google_apis" ];
    abiVersions = [ emulatorAbi ];
  };
  # Plugins can pin older compile SDKs too. Compose these separately because
  # nixpkgs also uses platformVersions to select multi-gigabyte system images.
  # Only API 36 should bring an emulator image into the full package.
  compatibilityPlatforms =
    (androidEnv.composeAndroidPackages {
      platformVersions = [
        "34"
        "35"
        "37"
      ];
    }).platforms;
  androidSdk = android.androidsdk.override (old: {
    postInstall =
      old.postInstall
      + pkgs.lib.concatMapStrings (platform: ''
        ln -s ${platform}/libexec/android-sdk/platforms/* "$ANDROID_HOME/platforms/"
      '') compatibilityPlatforms;
  });
  androidHome = "${androidSdk}/libexec/android-sdk";
in
{
  inherit buildToolsVersion emulatorAbi;

  packages = [
    flutter
    pkgs.jdk17
    androidSdk
    android.platform-tools
  ];

  env = {
    ANDROID_HOME = androidHome;
    ANDROID_SDK_ROOT = androidHome;
    ANDROID_NDK_ROOT = "${androidHome}/ndk/${ndkVersion}";
    JAVA_HOME = pkgs.jdk17.home;
    FLUTTER_ROOT = "${flutter}";
    GRADLE_OPTS = "-Dorg.gradle.project.android.aapt2FromMavenOverride=${androidHome}/build-tools/${buildToolsVersion}/aapt2";
    NETWORK_AUDIT_SYSTEM_IMAGE = "system-images;android-36;google_apis;${emulatorAbi}";
    FLUTTER_SUPPRESS_ANALYTICS = "true";
  };
}
