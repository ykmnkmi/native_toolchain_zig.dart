import 'dart:io';

import 'package:native_toolchain_zig/native_toolchain_zig.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

void main() {
  group('C import libc configuration', () {
    late Directory package;

    setUp(() async {
      package = await Directory.systemTemp.createTemp('zigchain_libc_test_');
      await File(path.join(package.path, 'pubspec.yaml'))
          .writeAsString('name: libc_test\n');
      await Directory(path.join(package.path, 'zig/src'))
          .create(recursive: true);
      await File(path.join(package.path, 'zig/src/root.zig')).writeAsString('''
const c = @cImport({
    @cInclude("assert.h");
    @cInclude("stdlib.h");
});
export fn magnitude(value: c_int) c_int { return c.abs(value); }
''');
    });

    tearDown(() => package.delete(recursive: true));

    Future<GeneratedBindingsResult> generate({bool? linkLibc}) {
      return generateBindingsSource(
        ZigBindingsOptions(
          packageRoot: package.path,
          output: 'lib/ffi.g.dart',
          linkLibc: linkLibc,
        ),
      );
    }

    Future<void> writeBuild(
      String settings, {
      String extra = '',
      String configure = '',
    }) {
      return File(path.join(package.path, 'zig/build.zig')).writeAsString('''
const std = @import("std");
pub fn build(b: *std.Build) void {
    $extra
    const module = b.createModule(.{
        .target = b.standardTargetOptions(.{}),
        .root_source_file = b.path("src/root.zig"),
        $settings
    });
    $configure
    const lib = b.addLibrary(.{ .name = "libc_test", .root_module = module });
    b.installArtifact(lib);
}
''');
    }

    test('checks builtin.link_libc for the selected module', () async {
      await writeBuild('.link_libc = true,');
      expect((await generate()).source, contains('external int magnitude('));
    });

    test('detects computed libc settings', () async {
      await writeBuild(
        '.link_libc = enabled,',
        extra: 'const enabled = @sizeOf(usize) > 0;',
      );
      expect((await generate()).functionCount, 1);
    });

    test(
      'compiles the probe for a cross target without executing it',
      () async {
        await writeBuild('.link_libc = true,');
        var result = await generateBindingsSource(
          ZigBindingsOptions(
            packageRoot: package.path,
            output: 'lib/ffi.g.dart',
            target: 'aarch64-linux-gnu',
          ),
        );
        expect(result.functionCount, 1);
      },
    );

    test('libc-disabled projects generate without libc headers', () async {
      await writeBuild('.link_libc = false,');
      await File(path.join(package.path, 'zig/src/root.zig'))
          .writeAsString('export fn value() i32 { return 1; }');
      expect((await generate()).functionCount, 1);
    });

    test('detects libc enabled through a module method', () async {
      await writeBuild('', configure: 'module.linkSystemLibrary("c", .{});');
      expect((await generate()).functionCount, 1);
    });

    test('rejects conflicting artifacts sharing the selected source', () async {
      await writeBuild(
        '.link_libc = true,',
        extra: '''
const other = b.createModule(.{
    .target = b.standardTargetOptions(.{}),
    .root_source_file = b.path("src/root.zig"),
    .link_libc = false,
});
b.installArtifact(b.addLibrary(.{ .name = "other", .root_module = other }));
''',
      );
      await expectLater(
        generate(),
        throwsA(
          isA<ProcessException>().having(
            (error) => error.message,
            'message',
            contains('Could not determine libc configuration'),
          ),
        ),
      );
      expect((await generate(linkLibc: true)).functionCount, 1);
    });

    test('reports build failures and cleans temporary wrappers', () async {
      await File(path.join(package.path, 'zig/build.zig'))
          .writeAsString('invalid Zig code');
      await expectLater(
        generate(),
        throwsA(
          isA<ProcessException>().having(
            (error) => error.message,
            'message',
            contains('Could not determine libc configuration'),
          ),
        ),
      );
      expect(
        Directory(path.join(package.path, 'zig')).listSync().where(
          (file) => path.basename(file.path).startsWith('.zigchain_probe_'),
        ),
        isEmpty,
      );
      expect((await generate(linkLibc: true)).functionCount, 1);
    });

    test('explicit true enables libc without a build file', () async {
      expect((await generate(linkLibc: true)).functionCount, 1);
    });

    test('explicit true overrides disabled libc', () async {
      await writeBuild('.link_libc = false,');
      expect((await generate(linkLibc: true)).functionCount, 1);
    });

    test('CLI supports libc overrides', () async {
      await writeBuild('.link_libc = false,');
      var result = await Process.run(Platform.resolvedExecutable, [
        'run',
        'native_toolchain_zig:zig',
        'bindings',
        '--package-root',
        package.path,
        '--link-libc',
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
    });

    // The Linux toolchain does not provide libc headers unless -lc is passed.
    for (var setting in ['', '.link_libc = false,', '// .link_libc = true,']) {
      test(
        'does not enable libc for absent, false, or commented setting: $setting',
        () async {
          await writeBuild(setting);
          await expectLater(
            generate(),
            throwsA(
              isA<ProcessException>().having(
                (error) => error.message,
                'message',
                anyOf(
                  contains("'assert.h' file not found"),
                  contains("'assert.h' not found"),
                ),
              ),
            ),
          );
        },
        testOn: 'linux',
      );
    }

    test('explicit false overrides enabled libc', () async {
      await writeBuild('.link_libc = true,');
      await expectLater(
        generate(linkLibc: false),
        throwsA(
          isA<ProcessException>().having(
            (error) => error.message,
            'message',
            anyOf(
              contains("'assert.h' file not found"),
              contains("'assert.h' not found"),
            ),
          ),
        ),
      );
    }, testOn: 'linux');

    test('ignores settings in strings and unrelated modules', () async {
      await writeBuild(
        '',
        extra: '''
const text = ".link_libc = true,";
_ = text;
_ = b.createModule(.{
    .root_source_file = b.path("src/other.zig"),
    .link_libc = true,
});
''',
      );
      await expectLater(
        generate(),
        throwsA(
          isA<ProcessException>().having(
            (error) => error.message,
            'message',
            anyOf(
              contains("'assert.h' file not found"),
              contains("'assert.h' not found"),
            ),
          ),
        ),
      );
    }, testOn: 'linux');
  });
}
