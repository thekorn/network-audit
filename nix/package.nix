{
  lib,
  stdenvNoCC,
  makeWrapper,
  python3,
  mitmproxy,
  openssl,
  nodejs_24,
  pkgs,
  withToolchain ? false,
}:

let
  python = python3.withPackages (ps: [
    ps.jinja2
    ps.jsonschema
  ]);
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
    nodejs_24
    pkgs.ps
  ];
  dontBuild = true;

  doCheck = true;
  checkPhase = ''
    runHook preCheck
    export HOME="$TMPDIR/home"
    export NETWORK_AUDIT_SCENARIO_RUNNER="${mobilewright}/runner.mjs"
    mkdir -p "$HOME"
    ${python}/bin/python3 -m unittest discover -s tests -v
    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/libexec/network-audit" "$out/bin"
    cp *.py ios_clone.m scenario.schema.json report.html.jinja "$out/libexec/network-audit/"
    makeWrapper ${python}/bin/python3 "$out/bin/network-audit" \
      --add-flags "$out/libexec/network-audit/cli.py" \
      --prefix PATH : ${lib.makeBinPath runtimePackages} \
      --set NETWORK_AUDIT_SCENARIO_RUNNER "${mobilewright}/runner.mjs" \
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

    # A syntax diagnostic proves scenario preflight loaded its bundled runtime
    # without Node/npm on the caller's PATH or a source checkout/node_modules.
    touch app.apk
    mkdir scenarios
    printf 'export default async function ( {\n' > scenarios/invalid.mjs
    printf 'executor = "invalid.mjs"\n' > scenarios/invalid.toml
    if env -i HOME="$HOME" "$out/bin/network-audit" "$TMPDIR/app.apk" \
      --scenario "$TMPDIR/scenarios/invalid.toml" > scenario.log 2>&1; then
      echo "Expected invalid executor syntax to fail" >&2
      exit 1
    fi
    grep -F 'Invalid executor syntax:' scenario.log
    grep -F 'SyntaxError' scenario.log
    printf 'domains = ["example.test"]\n' > scenarios/invalid.toml
    if env -i HOME="$HOME" "$out/bin/network-audit" "$TMPDIR/app.apk" \
      --scenario "$TMPDIR/scenarios/invalid.toml" > scenario.log 2>&1; then
      echo "Expected missing executor to fail schema validation" >&2
      exit 1
    fi
    grep -F "'executor' is a required property" scenario.log
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
