import 'dart:io';

import 'package:native_toolchain_zig/src/bindings_generator.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

void main() {
  late Directory package;
  setUp(() async {
    package = await Directory.systemTemp.createTemp('zigchain_abi_review_');
    await File(path.join(package.path, 'pubspec.yaml'))
        .writeAsString('name: abi_review\n');
    await Directory(path.join(package.path, 'zig/src')).create(recursive: true);
  });
  tearDown(() => package.delete(recursive: true));

  Future<void> checkZigLayout(String assertions) async {
    var root = File(path.join(package.path, 'zig/src/root.zig'));
    await root.writeAsString('\n$assertions', mode: FileMode.append);
    var result = await Process.run('zig', ['test', root.path]);
    expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
  }

  ZigApiDescription description(List<String> names) =>
      ZigApiDescription.fromJson({
        'types': [
          for (var name in names)
            {'name': name, 'kind': 'struct', 'layout': 'extern'},
        ],
      });

  test('exact names beat C tags in either declaration order', () {
    for (var names in [
      ['Thing', 'c_struct_Thing'],
      ['c_struct_Thing', 'Thing'],
    ]) {
      expect(description(names).typeDeclForName('Thing')?.name, 'Thing');
    }
  });

  test('ambiguous suffix matches fail instead of picking a layout', () {
    expect(
      () => description(['Left_Thing', 'Right_Thing']).typeDeclForName('Thing'),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('Ambiguous Zig type Thing'),
        ),
      ),
    );
    expect(
      description(['c_struct_Thing']).typeDeclForName('Thing')?.name,
      'c_struct_Thing',
    );
  });

  Future<String> generate(String source) async {
    await File(path.join(package.path, 'zig/src/root.zig'))
        .writeAsString(source);
    return (await generateBindingsSource(
      ZigBindingsOptions(packageRoot: package.path, output: 'lib/ffi.g.dart'),
    )).source;
  }

  test('exact type name wins over a suffix collision', () async {
    var generated = await generate('''
const Other_Thing = extern struct { large: u64 };
const Thing = extern struct { small: u8 };
export fn thing() Thing { return .{ .small = 1 }; }
''');
    expect(generated, contains('external Thing thing()'));
    expect(generated, contains('external int small;'));
    expect(generated, isNot(contains('class Other_Thing')));
  });

  test('packed structs with byte-sized fields are rejected', () async {
    await expectLater(
      generate('''
const Packed = packed struct { a: u8, b: u16 };
export fn packed_value() ?*Packed { return null; }
'''),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('Packed struct Packed'),
        ),
      ),
    );
    await checkZigLayout('''
test "packed backing integer layout" {
    try @import("std").testing.expectEqual(@as(usize, 4), @sizeOf(Packed));
    try @import("std").testing.expectEqual(@as(usize, 4), @alignOf(Packed));
}
''');
  });

  test('sentinel arrays reserve storage in every dimension', () async {
    var generated = await generate('''
const Packet = extern struct {
    buf: [3:0]u8,
    tail: u8,
    nested: [2][3:0]u8,
    empty: [0:0]u8,
};
export fn packet() ?*Packet { return null; }
''');
    expect(generated, contains('@ffi.Array(4)'));
    expect(generated, contains('@ffi.Array(2, 4)'));
    expect(generated, contains('@ffi.Array(1)'));
    await checkZigLayout('''
test "sentinel storage layout" {
    try @import("std").testing.expectEqual(@as(usize, 14), @sizeOf(Packet));
    try @import("std").testing.expectEqual(@as(usize, 4), @offsetOf(Packet, "tail"));
    try @import("std").testing.expectEqual(@as(usize, 13), @offsetOf(Packet, "empty"));
}
''');
    await File(path.join(package.path, 'bindings.dart'))
        .writeAsString(generated);
    await File(path.join(package.path, 'layout.dart')).writeAsString('''
import 'dart:ffi';
import 'package:ffi/ffi.dart';
import 'bindings.dart';
void main() {
  if (sizeOf<Packet>() != 14) throw StateError('Wrong Packet size: \${sizeOf<Packet>()}');
  final packet = calloc<Packet>();
  try {
    packet.ref.tail = 17;
    packet.ref.nested[1][3] = 99;
    packet.ref.empty[0] = 23;
    final bytes = packet.cast<Uint8>();
    if (bytes[4] != 17 || bytes[12] != 99 || bytes[13] != 23) {
      throw StateError('Dart field offsets do not match Zig');
    }
  } finally {
    calloc.free(packet);
  }
}
''');
    var result = await Process.run(Platform.resolvedExecutable, [
      '--packages=${path.absolute('.dart_tool/package_config.json')}',
      'run',
      path.join(package.path, 'layout.dart'),
    ]);
    expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
  });

  test('multiple C includes on one line translate successfully', () async {
    await File(path.join(package.path, 'zig/src/a.h'))
        .writeAsString('typedef int First;\n');
    await File(path.join(package.path, 'zig/src/b.h'))
        .writeAsString('typedef long Second;\n');
    var generated = await generate('''
const c = @cImport({ @cInclude("a.h"); @cInclude("b.h"); });
export fn first() c.First { return 1; }
export fn second() c.Second { return 2; }
''');
    expect(generated, contains('external int first()'));
    expect(generated, contains('external int second()'));
  });
}
