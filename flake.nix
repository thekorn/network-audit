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
        in
        {
          packages = {
            default = full;
            network-audit = full;
            network-audit-core = core;
          };
          # Never realize emulator images in orb/CI checks. The full package
          # must also be built and exercised on a supported native host.
          checks.network-audit = core;
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
          program = "${package}/bin/network-audit";
          meta.description = "Capture Android HTTP(S) traffic and generate offline audit reports";
        }) perSystem.${system}.packages
      );
      checks = forAllSystems (system: perSystem.${system}.checks);
      formatter = forAllSystems (system: perSystem.${system}.formatter);
    };
}
