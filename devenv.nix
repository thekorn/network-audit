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

    packages = toolchain.packages ++ [
      python
      pkgs.mitmproxy
      pkgs.pyright
      pkgs.openssl
      pkgs.nodejs_24
    ];

    scripts.network-audit.exec = ''
      exec ${python}/bin/python3 ${lib.escapeShellArg "${config.devenv.root}/network-audit/cli.py"} "$@"
    '';

    # Keep the audit in the foreground: oneshot tasks have a five-second
    # shutdown deadline that can interrupt cleanup and report generation.
    scripts.audit.exec = ''
      exec devenv shell -O androidEmulator.enable:bool true -- network-audit "$@"
    '';

    env = toolchain.env // {
      DEVENV_TOOLBOX = "network-audit";
      PUB_CACHE = "${config.devenv.state}/pub-cache";
      GRADLE_USER_HOME = "${config.devenv.state}/gradle";
      NETWORK_AUDIT_DEVENV = config.devenv.root;
      NETWORK_AUDIT_SCENARIO_RUNNER = "${mobilewright}/runner.mjs";
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
          '';

          "test:android-sdk".exec = ''
            set -euo pipefail
            test -f "$ANDROID_HOME/platforms/android-36/android.jar"
            test -x "$ANDROID_HOME/build-tools/${buildToolsVersion}/aapt2"
            test -f "$ANDROID_NDK_ROOT/source.properties"
            test -d "$ANDROID_HOME/cmake/3.22.1"
            ${lib.optionalString config.androidEmulator.enable ''
              test -x "$ANDROID_HOME/emulator/emulator"
              test -f "$ANDROID_HOME/system-images/android-36/google_apis/${emulatorAbi}/package.xml"
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
