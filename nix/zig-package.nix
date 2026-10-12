{
  lib,
  stdenv,
  makeWrapper,
  zig_0_17,
  python3,
  mitmproxy,
  openssl,
  nodejs_24,
  pkgs,
  withToolchain ? false,
}:

let
  python = python3.withPackages (ps: [ ps.jsonschema ]);
  mobilewright = pkgs.callPackage ./mobilewright.nix { inherit nodejs_24; };
  toolchain = import ./toolchain.nix {
    inherit pkgs;
    enableEmulator = true;
  };
  runtimePackages = [
    mitmproxy
    openssl
    nodejs_24
  ]
  ++ lib.optionals withToolchain toolchain.packages;
  environment = lib.optionalString withToolchain (
    lib.concatStringsSep " " (
      lib.mapAttrsToList (name: value: "--set ${name} ${lib.escapeShellArg value}") toolchain.env
    )
  );
  assets = lib.fileset.toSource {
    root = ../network-audit;
    fileset = lib.fileset.unions [
      ../network-audit/capture.py
      ../network-audit/domains.py
      ../network-audit/scenario.schema.json
    ];
  };
in
stdenv.mkDerivation {
  pname = if withToolchain then "network-audit-zig" else "network-audit-zig-core";
  version = "0.1.0";
  src = lib.fileset.toSource {
    root = ../network-audit-zig;
    fileset = lib.fileset.unions [
      ../network-audit-zig/build.zig
      ../network-audit-zig/src
      ../network-audit-zig/scenario_config.py
      ../network-audit-zig/tests
    ];
  };
  nativeBuildInputs = [
    zig_0_17
    makeWrapper
  ];
  nativeCheckInputs = [
    python
    nodejs_24
  ];
  # Contract tests start real processes, but never an Android emulator.
  postPatch = ''
    substituteInPlace src/{runtime,android,recording,scenario}.zig \
      --replace-quiet /bin/sh ${lib.getExe pkgs.bash}
  '';
  configurePhase = ''
    runHook preConfigure
    export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-cache"
    runHook postConfigure
  '';
  buildPhase = ''
    runHook preBuild
    zig build -Doptimize=ReleaseSafe -Dcpu=baseline -j$NIX_BUILD_CORES --summary all
    runHook postBuild
  '';
  doCheck = true;
  checkPhase = ''
    runHook preCheck
    zig build test -Doptimize=ReleaseSafe -Dcpu=baseline -j$NIX_BUILD_CORES --summary all
    runHook postCheck
  '';
  installPhase = ''
    runHook preInstall
    mkdir -p "$out/bin" "$out/libexec/network-audit-zig"
    cp zig-out/bin/network-audit-zig "$out/bin/"
    cp scenario_config.py "$out/libexec/network-audit-zig/"
    wrapProgram "$out/bin/network-audit-zig" \
      --prefix PATH : ${lib.makeBinPath runtimePackages} \
      --set NETWORK_AUDIT_PYTHON "${python}/bin/python3" \
      --set NETWORK_AUDIT_ASSETS "${assets}" \
      --set NETWORK_AUDIT_ZIG_CONFIG "$out/libexec/network-audit-zig/scenario_config.py" \
      --set NETWORK_AUDIT_SCENARIO_RUNNER "${mobilewright}/runner.mjs" \
      ${environment}
    runHook postInstall
  '';
  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    export NETWORK_AUDIT_ZIG_BIN="$out/bin/network-audit-zig"
    ${python}/bin/python3 -m unittest discover -s tests -v
    runHook postInstallCheck
  '';
  meta = {
    description = "Experimental Zig Android HTTP(S) audit and offline reports";
    homepage = "https://github.com/thekorn/network-audit";
    mainProgram = "network-audit-zig";
    platforms = [
      "x86_64-linux"
      "aarch64-darwin"
    ];
  };
}
