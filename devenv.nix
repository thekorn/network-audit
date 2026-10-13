{
  config,
  inputs,
  lib,
  pkgs,
  ...
}:

let
  toolchain = import ./nix/toolchain.nix {
    inherit pkgs;
    enableEmulator = config.androidEmulator.enable;
  };
  inherit (toolchain) buildToolsVersion emulatorAbi;
  androidHome = toolchain.env.ANDROID_HOME;
  python = pkgs.python3.withPackages (ps: [
    ps.jinja2
    ps.jsonschema
  ]);
  mobilewright = pkgs.callPackage ./nix/mobilewright.nix { };
in
{
  options.androidEmulator.enable = lib.mkEnableOption "the Android emulator and host-native API 36 image (Apple Silicon Macs or KVM-capable x86_64 Linux hosts, never orbs)";

  config = {
    # v2.4.0's generated latest-version file still says 2.3.1. Use the pinned
    # release's actual version, retaining warnings for real CLI mismatches.
    devenv.latestVersion =
      (builtins.fromTOML (builtins.readFile "${inputs.devenv}/Cargo.toml")).workspace.package.version;

    # iOS needs the host's full Xcode, not Nix's macOS-only SDK. Let Apple's
    # tools use xcode-select (or the caller's DEVELOPER_DIR) for SDK discovery.
    apple.sdk = null;
    # Xcode selects its own compiler driver for linking. Nix's LD=ld overrides
    # that selection and sends compiler flags directly to the linker.
    stdenv = lib.mkIf pkgs.stdenv.hostPlatform.isDarwin pkgs.stdenvNoCC;

    packages = toolchain.packages ++ [
      python
      pkgs.mitmproxy
      pkgs.pyright
      pkgs.openssl
      pkgs.nodejs_24
      pkgs.zig_0_17
    ];

    scripts.network-audit.exec = ''
      exec ${python}/bin/python3 ${lib.escapeShellArg "${config.devenv.root}/network-audit/cli.py"} "$@"
    '';

    scripts.network-audit-zig.exec = ''
      set -euo pipefail
      # Build in a subshell, then exec from the caller's original directory so
      # app/config/output paths and foreground signals retain their meaning.
      (
        cd ${lib.escapeShellArg "${config.devenv.root}/network-audit-zig"}
        zig build -Doptimize=ReleaseSafe
      )
      exec ${lib.escapeShellArg "${config.devenv.root}/network-audit-zig/zig-out/bin/network-audit-zig"} "$@"
    '';

    # Keep the audit in the foreground: oneshot tasks have a five-second
    # shutdown deadline that can interrupt cleanup and report generation.
    scripts.audit.exec = ''
      backend=android
      previous=
      for argument in "$@"; do
        if [[ "$previous" == --backend ]]; then
          backend="$argument"
        elif [[ "$argument" == --backend=* ]]; then
          backend="''${argument#--backend=}"
        fi
        previous="$argument"
      done
      if [[ "$backend" == ios ]]; then
        exec devenv shell -- network-audit "$@"
      fi
      exec devenv shell -O androidEmulator.enable:bool true -- network-audit "$@"
    '';

    scripts.audit-zig.exec = ''
      exec devenv shell -O androidEmulator.enable:bool true -- network-audit-zig "$@"
    '';

    env = toolchain.env // {
      DEVENV_TOOLBOX = "network-audit";
      PUB_CACHE = "${config.devenv.state}/pub-cache";
      GRADLE_USER_HOME = "${config.devenv.state}/gradle";
      NETWORK_AUDIT_DEVENV = config.devenv.root;
      NETWORK_AUDIT_SCENARIO_RUNNER = "${mobilewright}/runner.mjs";
      NETWORK_AUDIT_ASSETS = "${config.devenv.root}/network-audit";
      NETWORK_AUDIT_ZIG_CONFIG = "${config.devenv.root}/network-audit-zig/scenario_config.py";
      NETWORK_AUDIT_PYTHON = "${python}/bin/python3";
    };

    # Named tasks expose each result in devenv's test output. Keep successful
    # analysis/test logs visible too, including diagnostics and test totals.
    tasks =
      lib.mapAttrs
        (
          _: task:
          {
            before = [ "devenv:enterTest" ];
            cwd = config.devenv.root;
          }
          // task
        )
        {
          "test:toolchain".exec = ''
            set -euo pipefail
            flutter --version
            dart --version
            java -version
            adb version
            mitmdump --version
            node --version
            node "$NETWORK_AUDIT_SCENARIO_RUNNER" --check
            network-audit --help
            zig version
            network-audit-zig --help
          '';

          "test:android-sdk".exec = ''
            set -euo pipefail
            test -f "$ANDROID_HOME/platforms/android-34/android.jar"
            test -f "$ANDROID_HOME/platforms/android-35/android.jar"
            test -f "$ANDROID_HOME/platforms/android-36/android.jar"
            test -x "$ANDROID_HOME/build-tools/${buildToolsVersion}/aapt2"
            test -x "$ANDROID_HOME/build-tools/35.0.0/aapt2"
            test -f "$ANDROID_NDK_ROOT/source.properties"
            test -d "$ANDROID_HOME/cmake/3.22.1"
            ${lib.optionalString config.androidEmulator.enable ''
              test -x "$ANDROID_HOME/emulator/emulator"
              test -f "$ANDROID_HOME/system-images/android-36/google_apis/${emulatorAbi}/package.xml"
              test ! -d "$ANDROID_HOME/system-images/android-34"
              test ! -d "$ANDROID_HOME/system-images/android-35"
            ''}
          '';

          "test:pyright" = {
            exec = "pyright";
            showOutput = true;
          };

          "test:python" = {
            exec = "python3 -m unittest discover -s network-audit/tests -v";
            showOutput = true;
          };

          "test:zig" = {
            exec = ''
              set -euo pipefail
              zig fmt --check build.zig src
              zig build test --summary all
              zig build -Doptimize=ReleaseSafe
              python3 -m unittest discover -s tests -v
            '';
            cwd = "${config.devenv.root}/network-audit-zig";
            showOutput = true;
            after = [ "test:toolchain@completed" ];
          };

          "test:flutter-analyze" = {
            exec = "flutter analyze";
            cwd = "${config.devenv.root}/sample-app";
            showOutput = true;
            after = [ "test:toolchain@completed" ];
          };

          "test:flutter-tests" = {
            exec = "flutter test --reporter expanded";
            cwd = "${config.devenv.root}/sample-app";
            showOutput = true;
            # Serialize Flutter commands, but don't skip tests if analysis fails.
            after = [ "test:flutter-analyze@completed" ];
          };
        };
  };
}
