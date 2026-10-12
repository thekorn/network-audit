{
  description = "Capture Android HTTP(S) traffic and generate offline audit reports";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs =
    { nixpkgs, ... }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-darwin"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
      packagesFor =
        system:
        let
          # As in devenv, using the bundled SDK accepts the Android SDK license.
          pkgs = import nixpkgs {
            inherit system;
            config.allowUnfree = true;
          };
          core = pkgs.callPackage ./nix/package.nix { };
          full = core.override { withToolchain = true; };
          zigCore = pkgs.callPackage ./nix/zig-package.nix { };
        in
        {
          packages = {
            default = full;
            network-audit = full;
            network-audit-core = core;
            zig = zigCore.override { withToolchain = true; };
            zig-core = zigCore;
          };
          # Never realize emulator images in orb/CI checks. The full package
          # must also be built and exercised on a supported native host.
          checks = {
            network-audit = core;
            network-audit-zig = zigCore;
          };
          formatter = pkgs.nixfmt;
        };
      perSystem = forAllSystems packagesFor;
    in
    {
      packages = forAllSystems (system: perSystem.${system}.packages);
      apps = forAllSystems (
        system:
        nixpkgs.lib.mapAttrs (_: package: {
          type = "app";
          program = nixpkgs.lib.getExe package;
          meta.description = package.meta.description;
        }) perSystem.${system}.packages
      );
      checks = forAllSystems (system: perSystem.${system}.checks);
      formatter = forAllSystems (system: perSystem.${system}.formatter);
    };
}
