# Development environment

- This repository uses Nix and devenv for Flutter/Android development. Keep
  `devenv.lock` committed; update it deliberately, never during orb setup.
- In an orb, `.agents/setup` prepares the toolchain and Bash login shells export
  the full environment automatically. Otherwise use `devenv shell <command>`.
- Run `devenv test` to check the toolchain. Once an app exists, also run
  `flutter analyze`, `flutter test`, and `flutter build apk --debug` as relevant.
- Flutter and Android SDK files in `/nix/store` are immutable. Do not run
  `flutter upgrade` or install SDK components imperatively; update `devenv.nix`
  and the lockfile. Commit the app's `pubspec.lock` when adding the app.
- Orbs have no KVM: never enable `androidEmulator.enable`, install emulator
  images, create AVDs, or start an Android emulator in an orb. When working in
  an orb, use the `thekorn-amp-runner` runner for emulator verification. If it is
  unavailable, report the blocker rather than trying to emulate inside the orb.
- On an Apple Silicon Mac with Nix and devenv, running the Android emulator
  directly is supported; the runner is not required. Enable
  `androidEmulator.enable` locally and use the declared ARM64 image with macOS
  Hypervisor.Framework. Intel Macs are not supported by the pinned toolchain.
- Keep `.agents/resume` fast and free of package installs. Long-lived services
  belong in `.amp/services.yaml`, not lifecycle hooks.

# Git workflow

- Working directly on `main` is okay.
- Commit and push frequently, keeping changes small and focused.
