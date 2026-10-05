import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:test/test.dart';

void main() {
  test('watch ignores generated files and still follows C header edits', () async {
    var package = await Directory.systemTemp.createTemp('zigchain_watch_test_');
    addTearDown(() => package.delete(recursive: true));
    await File(path.join(package.path, 'pubspec.yaml'))
        .writeAsString('name: watch_test\n');
    var source = Directory(path.join(package.path, 'zig/src'));
    await source.create(recursive: true);
    var header = File(path.join(source.path, 'value.h'));
    await header.writeAsString('typedef int Value;\n');
    await File(path.join(source.path, 'root.zig')).writeAsString('''
const c = @cImport({ @cInclude("value.h"); });
export fn value() c.Value { return 0; }
''');

    var process = await Process.start(Platform.resolvedExecutable, [
      'run',
      'native_toolchain_zig:zig',
      'bindings',
      '--package-root',
      package.path,
      '--watch',
      '--no-link-libc',
      '--output',
      'zig/generated.dart',
      '--asset-id',
      'package:watch_test/ffi.g.dart',
    ]);
    var lines = <String>[];
    var errors = StringBuffer();
    var stdoutSubscription = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(lines.add);
    var stderrSubscription = process.stderr
        .transform(utf8.decoder)
        .listen(errors.write);
    addTearDown(() async {
      process.kill();
      await process.exitCode;
      await stdoutSubscription.cancel();
      await stderrSubscription.cancel();
    });

    int writes() => lines.where((line) => line.startsWith('Wrote ')).length;
    Future<void> waitFor(bool Function() condition) async {
      var deadline = DateTime.now().add(const Duration(seconds: 15));
      while (!condition()) {
        if (DateTime.now().isAfter(deadline)) {
          fail(
            'Timed out waiting for watch output:\n${lines.join('\n')}\n$errors',
          );
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }

    await waitFor(() => lines.any((line) => line.startsWith('Watching ')));
    await Future<void>.delayed(const Duration(milliseconds: 2200));
    expect(writes(), 1, reason: 'Generation must not trigger itself. $errors');

    for (var relative in [
      'src/.zigchain_cimport.zig',
      'src/.zigchain_cimport_source.c',
      '.zigchain_probe_test.zig',
      '.zigchain_probe_test.zig.zon',
      'src/.zig-cache/test',
      'src/zig-out/test',
    ]) {
      var file = File(path.join(package.path, 'zig', relative));
      await file.parent.create(recursive: true);
      await file.writeAsString('generated data');
    }
    await Future<void>.delayed(const Duration(milliseconds: 2200));
    expect(writes(), 1, reason: 'Temporary files must not trigger generation.');

    await header.writeAsString('typedef long Value;\n');
    await waitFor(() => writes() >= 2);
    var bindings = File(path.join(package.path, 'zig/generated.dart'));
    expect(await bindings.readAsString(), contains('ffi.Long Function()'));
    await Future<void>.delayed(const Duration(milliseconds: 2200));
    expect(writes(), 2, reason: 'One header edit should cause one generation.');
  }, timeout: const Timeout(Duration(seconds: 45)));
}
