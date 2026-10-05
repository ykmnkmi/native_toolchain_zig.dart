// ignore_for_file: unnecessary_final

import 'dart:io';

import 'package:native_toolchain_zig/src/bindings_generator.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

void main() {
  test('generateBindings emits typed enums from Zig source', () async {
    final tempDirectory = await Directory.systemTemp.createTemp(
      'native_toolchain_zig_bindings_test_',
    );
    addTearDown(() async {
      if (tempDirectory.existsSync()) {
        await tempDirectory.delete(recursive: true);
      }
    });

    await File(path.join(tempDirectory.path, 'pubspec.yaml'))
        .writeAsString('name: binding_test_package\n');
    await Directory(path.join(tempDirectory.path, 'zig', 'src'))
        .create(recursive: true);
    await File(path.join(tempDirectory.path, 'zig', 'src', 'root.zig'))
        .writeAsString('''
const Color = enum(c_int) {
    red = 1,
    green = 2,
    blue = 3,
};

const Point = extern struct {
    x: f32,
    y: f32,
};

export fn favorite_color() Color {
    return .green;
}

export fn next_color(color: Color) Color {
    return switch (color) {
        .red => .green,
        .green => .blue,
        .blue => .red,
    };
}

export fn make_point(x: f32, y: f32) Point {
    return Point{
        .x = x,
        .y = y,
    };
}

export fn native_long() c_long {
    return 0;
}
''');

    await generateBindings(
      ZigBindingsOptions(
        packageRoot: tempDirectory.path,
        output: 'lib/src/ffi.g.dart',
      ),
    );

    final generated = await File(
      path.join(tempDirectory.path, 'lib', 'src', 'ffi.g.dart'),
    ).readAsString();

    expect(generated, contains('enum Color {'));
    expect(generated, contains('red(1),'));
    expect(generated, contains('green(2),'));
    expect(
      generated,
      contains("@ffi.Native<ffi.Int32 Function()>(symbol: 'favorite_color')"),
    );
    expect(generated, contains('external int _favorite_colorRaw();'));
    expect(generated, contains('Color favorite_color() => '));
    expect(generated, contains('Color.fromValue(_favorite_colorRaw());'));
    expect(generated, contains('final class Point extends ffi.Struct {'));
    expect(
      generated,
      contains("@ffi.Native<ffi.Long Function()>(symbol: 'native_long')"),
    );
  });

  test(
    'generateBindings emits fixed-size array fields with valid FFI syntax',
    () async {
      final tempDirectory = await Directory.systemTemp.createTemp(
        'native_toolchain_zig_array_bindings_test_',
      );
      addTearDown(() async {
        if (tempDirectory.existsSync()) {
          await tempDirectory.delete(recursive: true);
        }
      });

      await File(path.join(tempDirectory.path, 'pubspec.yaml'))
          .writeAsString('name: binding_test_package\n');
      await Directory(path.join(tempDirectory.path, 'zig', 'src'))
          .create(recursive: true);
      await File(path.join(tempDirectory.path, 'zig', 'src', 'root.zig'))
          .writeAsString('''
const Point = extern struct {
    x: i32,
    y: i32,
};

const Packet = extern struct {
    bytes: [16]u8,
    points: [2]Point,
};

export fn make_packet() Packet {
    return .{
        .bytes = .{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 },
        .points = .{
            .{ .x = 1, .y = 2 },
            .{ .x = 3, .y = 4 },
        },
    };
}
''');

      await generateBindings(
        ZigBindingsOptions(
          packageRoot: tempDirectory.path,
          output: 'lib/src/ffi.g.dart',
        ),
      );

      final generated = await File(
        path.join(tempDirectory.path, 'lib', 'src', 'ffi.g.dart'),
      ).readAsString();

      expect(generated, contains('final class Packet extends ffi.Struct {'));
      expect(generated, contains('@ffi.Array(16)'));
      expect(generated, contains('external ffi.Array<ffi.Uint8> bytes;'));
      expect(generated, contains('@ffi.Array(2)'));
      expect(generated, contains('external ffi.Array<Point> points;'));
    },
  );

  test(
    'generateBindings emits function pointer callbacks with NativeFunction',
    () async {
      final tempDirectory = await Directory.systemTemp.createTemp(
        'native_toolchain_zig_callback_bindings_test_',
      );
      addTearDown(() async {
        if (tempDirectory.existsSync()) {
          await tempDirectory.delete(recursive: true);
        }
      });

      await File(path.join(tempDirectory.path, 'pubspec.yaml'))
          .writeAsString('name: binding_test_package\n');
      await Directory(path.join(tempDirectory.path, 'zig', 'src'))
          .create(recursive: true);
      await File(path.join(tempDirectory.path, 'zig', 'src', 'root.zig'))
          .writeAsString('''
const Callback = ?*const fn (value: i32, user: ?*anyopaque) callconv(.c) i32;

const Holder = extern struct {
    callback: Callback,
    user: ?*anyopaque,
};

export fn call_callback(callback: Callback, value: i32, user: ?*anyopaque) i32 {
    _ = user;
    return if (callback) |cb| cb(value, user) else 0;
}

export fn make_holder() Holder {
    return .{
        .callback = null,
        .user = null,
    };
}
''');

      await generateBindings(
        ZigBindingsOptions(
          packageRoot: tempDirectory.path,
          output: 'lib/src/ffi.g.dart',
        ),
      );

      final generated = await File(
        path.join(tempDirectory.path, 'lib', 'src', 'ffi.g.dart'),
      ).readAsString();

      expect(
        generated,
        contains(
          'typedef Callback = ffi.Int32 Function(ffi.Int32, ffi.Pointer<ffi.Void>);',
        ),
      );
      expect(
        generated,
        contains(
          'typedef call_callbackCallback = ffi.Int32 Function(ffi.Int32, ffi.Pointer<ffi.Void>);',
        ),
      );
      expect(
        generated,
        contains(
          'external ffi.Pointer<ffi.NativeFunction<ffi.Int32 Function(ffi.Int32, ffi.Pointer<ffi.Void>)>> callback;',
        ),
      );
      expect(
        generated,
        contains(
          "@ffi.Native<ffi.Int32 Function(ffi.Pointer<ffi.NativeFunction<ffi.Int32 Function(ffi.Int32, ffi.Pointer<ffi.Void>)>>, ffi.Int32, ffi.Pointer<ffi.Void>)>(symbol: 'call_callback')",
        ),
      );
      expect(
        generated,
        contains(
          'external int call_callback(ffi.Pointer<ffi.NativeFunction<ffi.Int32 Function(ffi.Int32, ffi.Pointer<ffi.Void>)>> callback, int value, ffi.Pointer<ffi.Void> user);',
        ),
      );
    },
  );

  test('generateBindings emits void callback function pointers', () async {
    final tempDirectory = await Directory.systemTemp.createTemp(
      'native_toolchain_zig_void_callback_bindings_test_',
    );
    addTearDown(() async {
      if (tempDirectory.existsSync()) {
        await tempDirectory.delete(recursive: true);
      }
    });

    await File(path.join(tempDirectory.path, 'pubspec.yaml'))
        .writeAsString('name: binding_test_package\n');
    await Directory(path.join(tempDirectory.path, 'zig', 'src'))
        .create(recursive: true);
    await File(path.join(tempDirectory.path, 'zig', 'src', 'root.zig'))
        .writeAsString('''
const Point = extern struct {
    x: i32,
    y: i32,
};

const VisitCallback = ?*const fn (point: Point, user: ?*anyopaque) callconv(.c) void;

const Listener = extern struct {
    callback: VisitCallback,
};

export fn visit_points(visit: VisitCallback, user: ?*anyopaque) void {
    _ = visit;
    _ = user;
}

export fn use_listener(listener: Listener) void {
    _ = listener;
}
''');

    await generateBindings(
      ZigBindingsOptions(
        packageRoot: tempDirectory.path,
        output: 'lib/src/ffi.g.dart',
      ),
    );

    final generated = await File(
      path.join(tempDirectory.path, 'lib', 'src', 'ffi.g.dart'),
    ).readAsString();

    expect(
      generated,
      contains(
        'typedef VisitCallback = ffi.Void Function(Point, ffi.Pointer<ffi.Void>);',
      ),
    );
    expect(
      generated,
      contains(
        'typedef Callback = ffi.Void Function(Point, ffi.Pointer<ffi.Void>);',
      ),
    );
    expect(
      generated,
      contains(
        'external ffi.Pointer<ffi.NativeFunction<ffi.Void Function(Point, ffi.Pointer<ffi.Void>)>> callback;',
      ),
    );
    expect(
      generated,
      contains(
        "@ffi.Native<ffi.Void Function(ffi.Pointer<ffi.NativeFunction<ffi.Void Function(Point, ffi.Pointer<ffi.Void>)>>, ffi.Pointer<ffi.Void>)>(symbol: 'visit_points')",
      ),
    );
    expect(
      generated,
      contains(
        "@ffi.Native<ffi.Void Function(Listener)>(symbol: 'use_listener')",
      ),
    );
  });

  test('generateBindings emits multi-dimensional array fields', () async {
    final tempDirectory = await Directory.systemTemp.createTemp(
      'native_toolchain_zig_multi_array_bindings_test_',
    );
    addTearDown(() async {
      if (tempDirectory.existsSync()) {
        await tempDirectory.delete(recursive: true);
      }
    });

    await File(path.join(tempDirectory.path, 'pubspec.yaml'))
        .writeAsString('name: binding_test_package\n');
    await Directory(path.join(tempDirectory.path, 'zig', 'src'))
        .create(recursive: true);
    await File(path.join(tempDirectory.path, 'zig', 'src', 'root.zig'))
        .writeAsString('''
const Grid = extern struct {
    bytes: [2][3]u8,
};

export fn make_grid() Grid {
    return .{
        .bytes = .{
            .{ 1, 2, 3 },
            .{ 4, 5, 6 },
        },
    };
}
''');

    await generateBindings(
      ZigBindingsOptions(
        packageRoot: tempDirectory.path,
        output: 'lib/src/ffi.g.dart',
      ),
    );

    final generated = await File(
      path.join(tempDirectory.path, 'lib', 'src', 'ffi.g.dart'),
    ).readAsString();

    expect(generated, contains('final class Grid extends ffi.Struct {'));
    expect(generated, contains('@ffi.Array(2, 3)'));
    expect(
      generated,
      contains('external ffi.Array<ffi.Array<ffi.Uint8>> bytes;'),
    );
  });

  test(
    'generateBindings rejects packed structs with byte-sized fields',
    () async {
      final tempDirectory = await Directory.systemTemp.createTemp(
        'native_toolchain_zig_packed_bindings_test_',
      );
      addTearDown(() async {
        if (tempDirectory.existsSync()) {
          await tempDirectory.delete(recursive: true);
        }
      });

      await File(path.join(tempDirectory.path, 'pubspec.yaml'))
          .writeAsString('name: binding_test_package\n');
      await Directory(path.join(tempDirectory.path, 'zig', 'src'))
          .create(recursive: true);
      await File(path.join(tempDirectory.path, 'zig', 'src', 'root.zig'))
          .writeAsString('''
const Packed = packed struct {
    a: u8,
    b: u32,
};

export fn make_packed() Packed {
    return .{
        .a = 1,
        .b = 2,
    };
}
''');

      await expectLater(
        generateBindings(
          ZigBindingsOptions(
            packageRoot: tempDirectory.path,
            output: 'lib/src/ffi.g.dart',
          ),
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('Packed struct Packed'),
          ),
        ),
      );
    },
  );

  test(
    'generateBindings rejects packed structs with bit-sized fields',
    () async {
      final tempDirectory = await Directory.systemTemp.createTemp(
        'native_toolchain_zig_packed_bool_test_',
      );
      addTearDown(() async {
        if (tempDirectory.existsSync()) {
          await tempDirectory.delete(recursive: true);
        }
      });

      await File(path.join(tempDirectory.path, 'pubspec.yaml'))
          .writeAsString('name: binding_test_package\n');
      await Directory(path.join(tempDirectory.path, 'zig', 'src'))
          .create(recursive: true);
      await File(path.join(tempDirectory.path, 'zig', 'src', 'root.zig'))
          .writeAsString('''
const Flags = packed struct { enabled: bool };
export fn flags() Flags { return .{ .enabled = true }; }
''');

      await expectLater(
        generateBindingsSource(
          ZigBindingsOptions(
            packageRoot: tempDirectory.path,
            output: 'lib/src/ffi.g.dart',
          ),
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('Packed struct Flags'),
          ),
        ),
      );
    },
  );

  test(
    'generateBindings rejects non-C and implicit callback conventions',
    () async {
      for (final convention in ['callconv(.fast)', '']) {
        final tempDirectory = await Directory.systemTemp.createTemp(
          'native_toolchain_zig_callback_convention_test_',
        );
        addTearDown(() async {
          if (tempDirectory.existsSync()) {
            await tempDirectory.delete(recursive: true);
          }
        });

        await File(path.join(tempDirectory.path, 'pubspec.yaml'))
            .writeAsString('name: binding_test_package\n');
        await Directory(path.join(tempDirectory.path, 'zig', 'src'))
            .create(recursive: true);
        await File(path.join(tempDirectory.path, 'zig', 'src', 'root.zig'))
            .writeAsString('''
const Callback = *const fn () $convention void;
export fn register(callback: Callback) void { _ = callback; }
''');

        await expectLater(
          generateBindingsSource(
            ZigBindingsOptions(
              packageRoot: tempDirectory.path,
              output: 'lib/src/ffi.g.dart',
            ),
          ),
          throwsA(isA<StateError>()),
        );
      }
    },
  );

  test('generateBindings carries comments into generated Dart', () async {
    final tempDirectory = await Directory.systemTemp.createTemp(
      'native_toolchain_zig_comment_bindings_test_',
    );
    addTearDown(() async {
      if (tempDirectory.existsSync()) {
        await tempDirectory.delete(recursive: true);
      }
    });

    await File(path.join(tempDirectory.path, 'pubspec.yaml'))
        .writeAsString('name: binding_test_package\n');
    await Directory(path.join(tempDirectory.path, 'zig', 'src'))
        .create(recursive: true);
    await File(path.join(tempDirectory.path, 'zig', 'src', 'root.zig'))
        .writeAsString('''
//! Root ABI comments should become library docs.
// Root note for generated bindings.

/// Public color enum.
const Color = enum(c_int) {
    //! Container docs belong with the type.
    // First color note.
    red = 1, // Red inline note.
    /// Second color note.
    green = 2,
};

/// A point in 2D.
const Point = extern struct {
    // Horizontal coordinate.
    x: f32, // Stored as f32.
    /// Vertical coordinate.
    y: f32,
};

/// Reads the current color.
export fn favorite_color(
    // Which color to return next.
    color: Color, // Parameter inline note.
) Color {
    return color;
}

/// Creates a point value.
export fn make_point(x: f32, y: f32) Point { // Function inline note.
    return .{
        .x = x,
        .y = y,
    };
}
''');

    await generateBindings(
      ZigBindingsOptions(
        packageRoot: tempDirectory.path,
        output: 'lib/src/ffi.g.dart',
      ),
    );

    final generated = await File(
      path.join(tempDirectory.path, 'lib', 'src', 'ffi.g.dart'),
    ).readAsString();

    expect(
      generated,
      contains('/// Root ABI comments should become library docs.'),
    );
    expect(generated, contains('/// Root note for generated bindings.'));
    expect(generated, contains('/// Public color enum.'));
    expect(generated, contains('/// Container docs belong with the type.'));
    expect(generated, contains('/// First color note.'));
    expect(generated, contains('/// Red inline note.'));
    expect(generated, contains('/// Second color note.'));
    expect(generated, contains('/// A point in 2D.'));
    expect(generated, contains('/// Horizontal coordinate.'));
    expect(generated, contains('/// Stored as f32.'));
    expect(generated, contains('/// Vertical coordinate.'));
    expect(generated, contains('/// Reads the current color.'));
    expect(generated, contains('/// Parameters:'));
    expect(generated, contains('/// - `color`: Which color to return next.'));
    expect(generated, contains('///   Parameter inline note.'));
    expect(generated, contains('/// Creates a point value.'));
    expect(generated, contains('/// Function inline note.'));
  });

  test(
    'generateBindings discovers imported modules and nested declarations',
    () async {
      final tempDirectory = await Directory.systemTemp.createTemp(
        'native_toolchain_zig_nested_bindings_test_',
      );
      addTearDown(() async {
        if (tempDirectory.existsSync()) {
          await tempDirectory.delete(recursive: true);
        }
      });

      await File(path.join(tempDirectory.path, 'pubspec.yaml'))
          .writeAsString('name: binding_test_package\n');
      await Directory(path.join(tempDirectory.path, 'zig', 'src'))
          .create(recursive: true);
      await File(path.join(tempDirectory.path, 'zig', 'src', 'root.zig'))
          .writeAsString('''
const api = @import("api.zig");

comptime {
    _ = api;
}
''');
      await File(path.join(tempDirectory.path, 'zig', 'src', 'api.zig'))
          .writeAsString('''
pub const abi = struct {
    pub const Color = enum(c_int) {
        red = 1,
        green = 2,
        blue = 3,
    };

    pub const Point = extern struct {
        x: f32,
        y: f32,
        color: Color,
    };
};

pub const exports = struct {
    export fn favorite_color() abi.Color {
        return .green;
    }

    export fn make_point(x: f32, y: f32, color: abi.Color) abi.Point {
        return .{
            .x = x,
            .y = y,
            .color = color,
        };
    }
};
''');

      await generateBindings(
        ZigBindingsOptions(
          packageRoot: tempDirectory.path,
          output: 'lib/src/ffi.g.dart',
        ),
      );

      final generated = await File(
        path.join(tempDirectory.path, 'lib', 'src', 'ffi.g.dart'),
      ).readAsString();

      expect(generated, contains('enum api_abi_Color {'));
      expect(
        generated,
        contains('final class api_abi_Point extends ffi.Struct {'),
      );
      expect(generated, contains('api_abi_Color get color =>'));
      expect(
        generated,
        contains("@ffi.Native<ffi.Int32 Function()>(symbol: 'favorite_color')"),
      );
      expect(generated, contains('api_abi_Color favorite_color() => '));
      expect(
        generated,
        contains(
          "@ffi.Native<api_abi_Point Function(ffi.Float, ffi.Float, ffi.Int32)>(symbol: 'make_point')",
        ),
      );
      expect(
        generated,
        contains(
          'api_abi_Point make_point(double x, double y, api_abi_Color color)',
        ),
      );
    },
  );

  test(
    'generateBindings resolves imported extern struct aliases used by value',
    () async {
      final tempDirectory = await Directory.systemTemp.createTemp(
        'native_toolchain_zig_alias_struct_bindings_test_',
      );
      addTearDown(() async {
        if (tempDirectory.existsSync()) {
          await tempDirectory.delete(recursive: true);
        }
      });

      await File(path.join(tempDirectory.path, 'pubspec.yaml'))
          .writeAsString('name: binding_test_package\n');
      await Directory(path.join(tempDirectory.path, 'zig', 'src'))
          .create(recursive: true);
      await File(path.join(tempDirectory.path, 'zig', 'src', 'root.zig'))
          .writeAsString('''
const api = @import("api.zig");

const TextScanOptions = api.TextScanOptions;

export fn normalize_options(options: TextScanOptions) TextScanOptions {
    return options;
}
''');
      await File(path.join(tempDirectory.path, 'zig', 'src', 'api.zig'))
          .writeAsString('''
pub const TextScanOptions = extern struct {
    start: usize,
    end: usize,
};
''');

      await generateBindings(
        ZigBindingsOptions(
          packageRoot: tempDirectory.path,
          output: 'lib/src/ffi.g.dart',
        ),
      );

      final generated = await File(
        path.join(tempDirectory.path, 'lib', 'src', 'ffi.g.dart'),
      ).readAsString();
      final normalizeAnnotation = [
        '@ffi.Native<api_TextScanOptions Function(api_TextScanOptions)>',
        "(symbol: 'normalize_options')",
      ].join();

      expect(
        generated,
        contains('final class api_TextScanOptions extends ffi.Struct {'),
      );
      expect(generated, contains(normalizeAnnotation));
      expect(
        generated,
        contains(
          'api_TextScanOptions normalize_options(api_TextScanOptions options)',
        ),
      );
    },
  );

  test(
    'generateBindings resolves direct import aliases used by value',
    () async {
      final tempDirectory = await Directory.systemTemp.createTemp(
        'native_toolchain_zig_direct_import_alias_bindings_test_',
      );
      addTearDown(() async {
        if (tempDirectory.existsSync()) {
          await tempDirectory.delete(recursive: true);
        }
      });

      await File(path.join(tempDirectory.path, 'pubspec.yaml'))
          .writeAsString('name: binding_test_package\n');
      await Directory(path.join(tempDirectory.path, 'zig', 'src'))
          .create(recursive: true);
      await File(path.join(tempDirectory.path, 'zig', 'src', 'root.zig'))
          .writeAsString('''
const TextScanOptions = @import("api.zig").TextScanOptions;

export fn normalize_options(options: TextScanOptions) TextScanOptions {
    return options;
}
''');
      await File(path.join(tempDirectory.path, 'zig', 'src', 'api.zig'))
          .writeAsString('''
pub const TextScanOptions = extern struct {
    start: usize,
    end: usize,
};
''');

      await generateBindings(
        ZigBindingsOptions(
          packageRoot: tempDirectory.path,
          output: 'lib/src/ffi.g.dart',
        ),
      );

      final generated = await File(
        path.join(tempDirectory.path, 'lib', 'src', 'ffi.g.dart'),
      ).readAsString();
      final normalizeAnnotation = [
        '@ffi.Native<api_TextScanOptions Function(api_TextScanOptions)>',
        "(symbol: 'normalize_options')",
      ].join();

      expect(
        generated,
        contains('final class api_TextScanOptions extends ffi.Struct {'),
      );
      expect(generated, contains(normalizeAnnotation));
      expect(
        generated,
        contains(
          'api_TextScanOptions normalize_options(api_TextScanOptions options)',
        ),
      );
    },
  );

  test('generateBindings resolves alias chains across imports', () async {
    final tempDirectory = await Directory.systemTemp.createTemp(
      'native_toolchain_zig_alias_chain_bindings_test_',
    );
    addTearDown(() async {
      if (tempDirectory.existsSync()) {
        await tempDirectory.delete(recursive: true);
      }
    });

    await File(path.join(tempDirectory.path, 'pubspec.yaml'))
        .writeAsString('name: binding_test_package\n');
    await Directory(path.join(tempDirectory.path, 'zig', 'src'))
        .create(recursive: true);
    await File(path.join(tempDirectory.path, 'zig', 'src', 'root.zig'))
        .writeAsString('''
const api = @import("api.zig");

const FirstAlias = api.TextScanOptions;
const SecondAlias = FirstAlias;

export fn normalize_options(options: SecondAlias) SecondAlias {
    return options;
}
''');
    await File(path.join(tempDirectory.path, 'zig', 'src', 'api.zig'))
        .writeAsString('''
pub const TextScanOptions = extern struct {
    start: usize,
    end: usize,
};
''');

    await generateBindings(
      ZigBindingsOptions(
        packageRoot: tempDirectory.path,
        output: 'lib/src/ffi.g.dart',
      ),
    );

    final generated = await File(
      path.join(tempDirectory.path, 'lib', 'src', 'ffi.g.dart'),
    ).readAsString();

    expect(
      generated,
      contains('final class api_TextScanOptions extends ffi.Struct {'),
    );
    expect(
      generated,
      contains(
        '@ffi.Native<api_TextScanOptions Function(api_TextScanOptions)>',
      ),
    );
    expect(
      generated,
      contains(
        'api_TextScanOptions normalize_options(api_TextScanOptions options)',
      ),
    );
  });

  test('generateBindingsSource reports reachable Zig dependencies', () async {
    final tempDirectory = await Directory.systemTemp.createTemp(
      'native_toolchain_zig_dependency_bindings_test_',
    );
    addTearDown(() async {
      if (tempDirectory.existsSync()) {
        await tempDirectory.delete(recursive: true);
      }
    });

    await File(path.join(tempDirectory.path, 'pubspec.yaml'))
        .writeAsString('name: binding_test_package\n');
    await Directory(path.join(tempDirectory.path, 'zig', 'src'))
        .create(recursive: true);
    await File(path.join(tempDirectory.path, 'zig', 'src', 'root.zig'))
        .writeAsString('''
const api = @import("api.zig");

comptime {
    _ = api;
}
''');
    await File(path.join(tempDirectory.path, 'zig', 'src', 'api.zig'))
        .writeAsString('''
pub const exports = struct {
    export fn answer() i32 {
        return 42;
    }
};
''');

    final result = await generateBindingsSource(
      ZigBindingsOptions(
        packageRoot: tempDirectory.path,
        output: 'lib/src/ffi.g.dart',
      ),
    );

    expect(
      result.dependencies,
      contains(path.join(tempDirectory.path, 'zig', 'src', 'root.zig')),
    );
    expect(
      result.dependencies,
      contains(path.join(tempDirectory.path, 'zig', 'src', 'api.zig')),
    );
    expect(
      result.outputPath,
      path.join(tempDirectory.path, 'lib', 'src', 'ffi.g.dart'),
    );
    expect(result.functionCount, 1);
  });

  test('generateBindings ignores function-local export declarations', () async {
    final tempDirectory = await Directory.systemTemp.createTemp(
      'native_toolchain_zig_local_export_bindings_test_',
    );
    addTearDown(() async {
      if (tempDirectory.existsSync()) {
        await tempDirectory.delete(recursive: true);
      }
    });

    await File(path.join(tempDirectory.path, 'pubspec.yaml'))
        .writeAsString('name: binding_test_package\n');
    await Directory(path.join(tempDirectory.path, 'zig', 'src'))
        .create(recursive: true);
    await File(path.join(tempDirectory.path, 'zig', 'src', 'root.zig'))
        .writeAsString('''
pub fn helper() void {
    const Local = struct {
        export fn hidden() i32 {
            return 42;
        }
    };

    _ = Local;
}
''');

    await expectLater(
      () => generateBindings(
        ZigBindingsOptions(
          packageRoot: tempDirectory.path,
          output: 'lib/src/ffi.g.dart',
        ),
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('No exported Zig declarations were discovered'),
        ),
      ),
    );
  });
}
