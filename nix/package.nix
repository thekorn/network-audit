{
  lib,
  stdenvNoCC,
  makeWrapper,
  python3,
  mitmproxy,
  openssl,
  pkgs,
  withToolchain ? false,
}:

let
  python = python3.withPackages (ps: [ ps.jinja2 ]);
  toolchain = import ./toolchain.nix {
    inherit pkgs;
    enableEmulator = true;
  };
  runtimePackages = [
    mitmproxy
    openssl
  ]
  ++ lib.optionals withToolchain toolchain.packages;
  environment = lib.optionalString withToolchain (
    lib.concatStringsSep " " (
      lib.mapAttrsToList (name: value: "--set ${name} ${lib.escapeShellArg value}") toolchain.env
    )
  );
in
stdenvNoCC.mkDerivation {
  pname = if withToolchain then "network-audit" else "network-audit-core";
  version = "1";
  src = lib.cleanSource ../network-audit;

  nativeBuildInputs = [ makeWrapper ];
  nativeCheckInputs = [
    python
    mitmproxy
    openssl
  ];
  dontBuild = true;

  doCheck = true;
  checkPhase = ''
    runHook preCheck
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME"
    ${python}/bin/python3 -m unittest discover -s tests -v
    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/libexec/network-audit" "$out/bin"
    cp *.py report.html.jinja "$out/libexec/network-audit/"
    makeWrapper ${python}/bin/python3 "$out/bin/network-audit" \
      --add-flags "$out/libexec/network-audit/cli.py" \
      --prefix PATH : ${lib.makeBinPath runtimePackages} \
      ${environment}
    runHook postInstall
  '';

  # Exercise the installed entrypoint, imports and template without the source
  # tree, caller's Python/SDK environment, or an Android device.
  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    cd "$TMPDIR"
    env -i HOME="$HOME" "$out/bin/network-audit" --help
    mkdir session
    echo '{"app":"Packaged <APK>","domains":["example.test"],"started":"2026-10-10T00:00:00Z","state":"interrupted"}' > session/session.json
    env -i HOME="$HOME" "$out/bin/network-audit" report session
    grep -F 'Packaged &lt;APK&gt;' session/report.html
    grep -F 'No matching HTTP exchanges captured' session/report.html
    runHook postInstallCheck
  '';

  meta = {
    description = "Capture Android HTTP(S) traffic and generate offline audit reports";
    homepage = "https://github.com/thekorn/network-audit";
    mainProgram = "network-audit";
    platforms = [
      "x86_64-linux"
      "aarch64-darwin"
    ];
  };
}
