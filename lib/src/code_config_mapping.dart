import 'package:code_assets/code_assets.dart';

extension CodeConfigMapping on CodeConfig {
  LinkMode get linkMode {
    return switch (linkModePreference) {
      LinkModePreference.dynamic ||
      LinkModePreference.preferDynamic => DynamicLoadingBundled(),
      LinkModePreference.static ||
      LinkModePreference.preferStatic => StaticLinking(),
      _ => throw UnsupportedError(
        'Unsupported link mode: $linkModePreference.',
      ),
    };
  }

  (String, String, String) get targetTriple {
    return mapOsAndArch(targetOS, targetArchitecture, iOS.targetSdk);
  }
}

(String, String, String) mapOsAndArch(
  OS os,
  Architecture arch, [
  IOSSdk? iOSTarget,
]) {
  return switch ((os, arch)) {
    // Android
    (OS.android, Architecture.arm64) => ('aarch64', 'linux', 'android'),
    (OS.android, Architecture.arm) => ('arm', 'linux', 'androideabi'),
    (OS.android, Architecture.x64) => ('x86_64', 'linux', 'android'),

    // iOS
    (OS.iOS, Architecture.arm64) => switch (iOSTarget) {
      IOSSdk.iPhoneOS || null => ('aarch64', 'ios', 'none'),
      IOSSdk.iPhoneSimulator => ('aarch64', 'ios', 'simulator'),
      _ => throw UnsupportedError('Unknown IOSSdk: $iOSTarget'),
    },
    (OS.iOS, Architecture.x64) => ('x86_64', 'ios', 'simulator'),

    // Windows
    (OS.windows, Architecture.arm64) => ('aarch64', 'windows', 'gnu'),
    (OS.windows, Architecture.x64) => ('x86_64', 'windows', 'gnu'),

    // Linux
    (OS.linux, Architecture.arm64) => ('aarch64', 'linux', 'gnu'),
    (OS.linux, Architecture.x64) => ('x86_64', 'linux', 'gnu'),

    // macOS
    (OS.macOS, Architecture.arm64) => ('aarch64', 'macos', 'none'),
    (OS.macOS, Architecture.x64) => ('x86_64', 'macos', 'none'),

    (_, _) => throw UnsupportedError('Unsupported target: $os on $arch.'),
  };
}
