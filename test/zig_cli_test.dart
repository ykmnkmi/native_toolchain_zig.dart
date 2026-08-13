// ignore_for_file: unnecessary_final

import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:test/test.dart';

void main() {
  test('zig CLI generates bindings for a Zig package', () async {
    final tempDirectory = await Directory.systemTemp.createTemp(
      'native_toolchain_zig_cli_test_',
    );
    addTearDown(() async {
      if (tempDirectory.existsSync()) {
        await tempDirectory.delete(recursive: true);
      }
    });

    await File(
      path.join(tempDirectory.path, 'pubspec.yaml'),
    ).writeAsString('name: cli_binding_test_package\n');
    await Directory(
      path.join(tempDirectory.path, 'zig', 'src'),
    ).create(recursive: true);
    await File(path.join(tempDirectory.path, 'zig', 'build.zig')).writeAsString(
      '''
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib = b.addLibrary(.{
        .name = "cli_binding_test_package",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    b.installArtifact(lib);
}
''',
    );
    await File(
      path.join(tempDirectory.path, 'zig', 'src', 'root.zig'),
    ).writeAsString('''
const Point = extern struct {
    x: f32,
    y: f32,
};

export fn make_point(x: f32, y: f32) Point {
    return .{ .x = x, .y = y };
}
''');

    final result = await Process.run(Platform.resolvedExecutable, [
      'run',
      'native_toolchain_zig:zig',
      'bindings',
      '--package-root',
      tempDirectory.path,
      '--output',
      'lib/src/ffi.g.dart',
    ], workingDirectory: Directory.current.path);

    expect(
      result.exitCode,
      equals(0),
      reason: 'stdout:\n${result.stdout}\nstderr:\n${result.stderr}',
    );
    expect(
      result.stdout,
      contains(
        'Generating bindings for 1 function(s), 0 global(s), and 1 ABI type(s)...',
      ),
    );

    final generated = await File(
      path.join(tempDirectory.path, 'lib', 'src', 'ffi.g.dart'),
    ).readAsString();

    expect(generated, contains('final class Point extends ffi.Struct {'));
    expect(
      generated,
      contains(
        "@ffi.Native<Point Function(ffi.Float, ffi.Float)>(symbol: 'make_point')",
      ),
    );
  });

  test('zig CLI prints command usage', () async {
    final result = await Process.run(Platform.resolvedExecutable, [
      'run',
      'native_toolchain_zig:zig',
      '--help',
    ], workingDirectory: Directory.current.path);

    expect(result.exitCode, equals(0));
    expect(
      result.stdout,
      contains('Usage: dart run native_toolchain_zig:zig <command> [options]'),
    );
  });
}
