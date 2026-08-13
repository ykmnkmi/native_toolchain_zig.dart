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

    await File(
      path.join(tempDirectory.path, 'pubspec.yaml'),
    ).writeAsString('name: binding_test_package\n');
    await Directory(
      path.join(tempDirectory.path, 'zig', 'src'),
    ).create(recursive: true);
    await File(
      path.join(tempDirectory.path, 'zig', 'src', 'root.zig'),
    ).writeAsString('''
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
      contains("@ffi.Native<ffi.Int Function()>(symbol: 'favorite_color')"),
    );
    expect(generated, contains('external int _favorite_colorRaw();'));
    expect(generated, contains('Color favorite_color() => '));
    expect(generated, contains('Color.fromValue(_favorite_colorRaw());'));
    expect(generated, contains('final class Point extends ffi.Struct {'));
  });

  test('generateBindings carries comments into generated Dart', () async {
    final tempDirectory = await Directory.systemTemp.createTemp(
      'native_toolchain_zig_comment_bindings_test_',
    );
    addTearDown(() async {
      if (tempDirectory.existsSync()) {
        await tempDirectory.delete(recursive: true);
      }
    });

    await File(
      path.join(tempDirectory.path, 'pubspec.yaml'),
    ).writeAsString('name: binding_test_package\n');
    await Directory(
      path.join(tempDirectory.path, 'zig', 'src'),
    ).create(recursive: true);
    await File(
      path.join(tempDirectory.path, 'zig', 'src', 'root.zig'),
    ).writeAsString('''
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

      await File(
        path.join(tempDirectory.path, 'pubspec.yaml'),
      ).writeAsString('name: binding_test_package\n');
      await Directory(
        path.join(tempDirectory.path, 'zig', 'src'),
      ).create(recursive: true);
      await File(
        path.join(tempDirectory.path, 'zig', 'src', 'root.zig'),
      ).writeAsString('''
const api = @import("api.zig");

comptime {
    _ = api;
}
''');
      await File(
        path.join(tempDirectory.path, 'zig', 'src', 'api.zig'),
      ).writeAsString('''
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
        contains("@ffi.Native<ffi.Int Function()>(symbol: 'favorite_color')"),
      );
      expect(generated, contains('api_abi_Color favorite_color() => '));
      expect(
        generated,
        contains(
          "@ffi.Native<api_abi_Point Function(ffi.Float, ffi.Float, ffi.Int)>(symbol: 'make_point')",
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

      await File(
        path.join(tempDirectory.path, 'pubspec.yaml'),
      ).writeAsString('name: binding_test_package\n');
      await Directory(
        path.join(tempDirectory.path, 'zig', 'src'),
      ).create(recursive: true);
      await File(
        path.join(tempDirectory.path, 'zig', 'src', 'root.zig'),
      ).writeAsString('''
const api = @import("api.zig");

const TextScanOptions = api.TextScanOptions;

export fn normalize_options(options: TextScanOptions) TextScanOptions {
    return options;
}
''');
      await File(
        path.join(tempDirectory.path, 'zig', 'src', 'api.zig'),
      ).writeAsString('''
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

      await File(
        path.join(tempDirectory.path, 'pubspec.yaml'),
      ).writeAsString('name: binding_test_package\n');
      await Directory(
        path.join(tempDirectory.path, 'zig', 'src'),
      ).create(recursive: true);
      await File(
        path.join(tempDirectory.path, 'zig', 'src', 'root.zig'),
      ).writeAsString('''
const TextScanOptions = @import("api.zig").TextScanOptions;

export fn normalize_options(options: TextScanOptions) TextScanOptions {
    return options;
}
''');
      await File(
        path.join(tempDirectory.path, 'zig', 'src', 'api.zig'),
      ).writeAsString('''
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

  test('generateBindingsSource reports reachable Zig dependencies', () async {
    final tempDirectory = await Directory.systemTemp.createTemp(
      'native_toolchain_zig_dependency_bindings_test_',
    );
    addTearDown(() async {
      if (tempDirectory.existsSync()) {
        await tempDirectory.delete(recursive: true);
      }
    });

    await File(
      path.join(tempDirectory.path, 'pubspec.yaml'),
    ).writeAsString('name: binding_test_package\n');
    await Directory(
      path.join(tempDirectory.path, 'zig', 'src'),
    ).create(recursive: true);
    await File(
      path.join(tempDirectory.path, 'zig', 'src', 'root.zig'),
    ).writeAsString('''
const api = @import("api.zig");

comptime {
    _ = api;
}
''');
    await File(
      path.join(tempDirectory.path, 'zig', 'src', 'api.zig'),
    ).writeAsString('''
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

    await File(
      path.join(tempDirectory.path, 'pubspec.yaml'),
    ).writeAsString('name: binding_test_package\n');
    await Directory(
      path.join(tempDirectory.path, 'zig', 'src'),
    ).create(recursive: true);
    await File(
      path.join(tempDirectory.path, 'zig', 'src', 'root.zig'),
    ).writeAsString('''
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
