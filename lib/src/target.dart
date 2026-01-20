import 'package:code_assets/code_assets.dart';

/// Zig build optimization levels.
enum Optimization {
  /// Debug mode with safety checks and debug info.
  debug('Debug'),

  /// Release mode with safety checks enabled.
  releaseSafe('ReleaseSafe'),

  /// Release mode optimized for runtime performance.
  releaseFast('ReleaseFast'),

  /// Release mode optimized for binary size.
  releaseSmall('ReleaseSmall');

  const Optimization(this.name);

  final String name;
}

/// Represents a Zig cross-compilation target.
///
/// Maps between Dart's [OS]/[Architecture] and Zig's target triple format.
final class Target {
  /// Creates a [Target] from Dart's [OS] and [Architecture].
  ///
  /// Throws [UnsupportedError] if the platform is not supported.
  factory Target.from(Architecture arch, OS os, LinkMode linkMode) {
    String archStr = _mapArch(arch);
    var (String osStr, String? abiStr) = _mapOS(os);
    return Target(arch: archStr, os: osStr, abi: abiStr, linkMode: linkMode);
  }

  /// Creates a [Target] with explicit components.
  const Target({
    required this.arch,
    required this.os,
    this.abi,
    required this.linkMode,
  });

  /// The architecture (e.g., 'x86_64', 'aarch64').
  final String arch;

  /// The operating system (e.g., 'linux', 'macos', 'windows').
  final String os;

  /// The ABI (e.g., 'gnu', 'musl', 'android'). May be null.
  final String? abi;

  final LinkMode linkMode;

  /// The library file prefix for this target ('lib' or '').
  String get libraryPrefix {
    return switch (os) {
      'windows' => '',
      _ => 'lib',
    };
  }

  /// The library file extension for this target.
  String get libraryExtension {
    return switch (os) {
      'windows' => '.dll',
      'macos' || 'ios' => '.dylib',
      _ => '.so',
    };
  }

  /// The full target triple string for Zig.
  ///
  /// Examples: `x86_64-linux-gnu`, `aarch64-macos`, `x86_64-windows-gnu`
  String get triple {
    return abi == null ? '$arch-$os' : '$arch-$os-$abi';
  }

  /// Returns the expected library file name for this target.
  String libraryFileName(String name) {
    return switch (os) {
      'windows' => '$name.dll',
      'macos' || 'ios' => 'lib$name.dylib',
      _ => 'lib$name.so',
    };
  }

  static String _mapArch(Architecture arch) {
    return switch (arch) {
      Architecture.arm => 'arm',
      Architecture.arm64 => 'aarch64',
      Architecture.ia32 => 'x86',
      Architecture.riscv32 => 'riscv32',
      Architecture.riscv64 => 'riscv64',
      Architecture.x64 => 'x86_64',
      _ => throw UnsupportedError('Unsupported architecture: $arch'),
    };
  }

  static (String os, String? abi) _mapOS(OS os) {
    return switch (os) {
      OS.android => ('linux', 'android'),
      OS.fuchsia => ('fuchsia', null),
      OS.iOS => ('ios', null),
      OS.linux => ('linux', 'gnu'),
      OS.macOS => ('macos', null),
      OS.windows => ('windows', 'gnu'),
      _ => throw UnsupportedError('Unsupported OS: $os'),
    };
  }
}
