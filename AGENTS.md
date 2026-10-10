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
  images, create AVDs, or start an Android emulator in an orb. Native device
  verification needs a connected KVM-capable host/runner or Android device.
- Whenever an Android emulator is needed, use the `thekorn-amp-runner` runner.
  If it is unavailable, report the blocker rather than trying to run an emulator
  in an orb.
- Keep `.agents/resume` fast and free of package installs. Long-lived services
  belong in `.amp/services.yaml`, not lifecycle hooks.
