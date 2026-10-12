# Experimental Zig audit

A Zig **0.17.0** port for comparing development and maintenance with the Python
implementation. Python remains the default: `audit`, `network-audit`, `nix run .`
and the flake's default package are unchanged.

## Run

On Apple Silicon macOS or x86_64 Linux with writable `/dev/kvm`, from the
repository root:

```bash
devenv shell audit-zig sample-app --domain dummyjson.com --headless
devenv shell audit-zig sample-app --scenario sample-app/scenarios/browse.toml --record
```

`audit-zig` enables the same emulator toolchain as `audit`. It builds the local
Zig sources, then replaces the shell with `network-audit-zig`, keeping the caller's
working directory and foreground signal handling. Do not use a devenv oneshot
task for the capture; its shutdown deadline can interrupt cleanup.

The flake installs a compiled `network-audit-zig` command (no compiler needed at
runtime). The `zig` output includes the same Flutter/Android toolchain as the
Python default, including the multi-gigabyte API 36 emulator image:

```bash
nix run .#zig -- /path/to/app.apk --domain api.example.com
nix run --refresh 'github:thekorn/network-audit?ref=feature/network-audit-zig#zig' -- /path/to/app.apk --domain api.example.com
```

Until this branch is merged, the explicit `ref` is required for remote use.
After merge the shorter spelling is:

```bash
nix run --refresh github:thekorn/network-audit#zig -- /path/to/app.apk --domain api.example.com
```

For help or regenerating a report **without an emulator**, including inside an
orb, use the `zig-core` output or the development command:

```bash
devenv shell network-audit-zig --help
devenv shell network-audit-zig report /path/to/session
nix run .#zig-core -- report /path/to/session
```

Never enable the emulator or build the full `zig` package inside an orb.
Native audits need at least 8 GiB free on the temporary filesystem. `TMPDIR`
can select another filesystem; `--output` only moves reports. The SDK license,
host restrictions and capture limitations are the same as for Python.

## What is ported

Zig owns argument parsing and configuration precedence, Flutter/FVM builds,
private AVD creation and cleanup, system/Conscrypt CA installation, proxy and
scenario process ownership, foreground monitoring, screen-recording finalization,
session metadata, event recovery, HTML reports and text summaries.

The experiment deliberately shares these existing boundaries:

- **mitmproxy:** uses `network-audit/capture.py` and `domains.py` unchanged, so
  capture filtering, previews, TLS diagnostics and `flows.mitm` keep their format.
- **TOML/JSON Schema:** the small `scenario_config.py` codec uses Python's
  `tomllib` and the existing JSON Schema. Zig resolves paths, applies overrides,
  validates executors and runs the scenario. This avoids adding a new TOML/schema
  dependency; it is not a Python-free distribution.
- **Mobilewright:** uses the existing locked Node.js runtime and JavaScript
  executors unchanged. Zig owns its private daemon and child process groups.

The Zig CLI does **not** call Python's CLI, Android orchestration, recording or
report generator. Report generation itself needs no Python, Jinja or Node.
Static report markup/CSS/JavaScript is copied from the Python template, with
compile-time checked markers replacing Jinja; keep both copies in sync during
this experiment rather than changing the default implementation.

Use the [Python tool's usage guide](../network-audit/README.md) for the shared
flags, domain semantics, scenario TOML, dimensions, flavors, Dart define files
and recording limits. `--help` lists the Zig CLI's options. Manual runs require
domains; scenarios without `domains` capture all HTTP(S) reaching the proxy.
Both versions can regenerate each other's sessions without changing capture
files. New session directories are private (0700), and new files are 0600.

Exit status is 0 for a completed/manual-interrupted audit, 130 for interruption
before session creation or during a scenario, and 1 for failures (including invalid
arguments; Python's argparse uses 2 for syntax errors). Failures after session
creation still attempt cleanup and produce a partial report. SIGINT/SIGTERM
are deferred during cleanup. Headers, cookies, tokens and bodies are **not
redacted**.

## Develop and check

The existing lockfiles already pin `pkgs.zig_0_17`; no alternate compiler download
or floating Zig input is used. Both `devenv shell` and the Nix builder select it
explicitly rather than nixpkgs' default Zig version.

```bash
devenv shell
zig version                          # 0.17.0
devenv test                          # includes Zig and existing Python/Flutter checks
nix flake check                      # core packages only; no emulator images
nix flake check --all-systems --no-build
```

Inside `network-audit-zig`, `zig build` builds the binary and `zig build test`
runs tests for reports, configuration, child processes, fake Android commands,
recording and scenario cleanup. `python3 -m unittest discover -s tests -v` checks
the built public CLI. Nix runs those checks against its installed wrapper from
outside the checkout with an empty caller environment.

Native acceptance is separate: run the sample scenario with `--record`, inspect
captured HTTPS exchanges and the MP4, then exercise manual Ctrl+C and a scenario
failure/timeout. At initial verification the Linux runner built the full package
but capture was blocked by 4.30–5.21 GiB free versus the 8 GiB preflight requirement;
no real-emulator capture or macOS execution has been verified for this port yet.
