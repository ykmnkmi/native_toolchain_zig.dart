# 🔧 native_toolchain_zig

[![Pub Version][pub_badge]][pub_link]
[![Dart CI][dart_ci]][dart_ci_link]
[![License: MIT][license_badge]][license_link]

Build Zig libraries with Dart's [build hooks][dart_hooks] and generate Dart FFI
bindings from exported Zig declarations. The build hook compiles and bundles the
native library; the bindings CLI generates the Dart API that calls it.

The generator reads Zig source directly and uses `zig translate-c` for supported
`@cImport` declarations. You can generate bindings without maintaining a separate
C header for your exported Zig functions.

### Prerequisites

- Dart SDK **3.13.0 or later**, within the Dart 3 release series.
- [Zig][zig_download] installed and available as `zig` on `PATH`.
  CI covers **Zig 0.15.2 and 0.16.0**.

### Installation

```bash
dart pub add hooks native_toolchain_zig
```

### Project Setup

1. Create your Zig project in `my_project/zig/`:

```
my_package/
├── bin/
│   └── main.dart
├── hook/
│   └── build.dart
├── lib/
│   └── my_package.dart
├── zig/
│   ├── src/
│   │   └── lib.zig
│   ├── build.zig
│   └── build.zig.zon
└── pubspec.yaml
```

2. Create `hook/build.dart`:

```dart
import 'package:hooks/hooks.dart';
import 'package:native_toolchain_zig/native_toolchain_zig.dart';

Future<void> main(List<String> arguments) async {
  await build(arguments, (input, output) async {
    await ZigBuilder(
      assetName: 'my_package.dart',
      zigDir: 'zig/',
    ).run(input: input, output: output);
  });
}
```

3. Create `zig/build.zig`:

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib = b.addLibrary(.{
        .name = "my_package",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lib.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    b.installArtifact(lib);
}
```

For a build that produces both static and dynamic libraries, see the
[bindings example's build script][bindings_build]. Custom build options can be
passed through `ZigBuilder.extraArguments`.

4. Create `zig/build.zig.zon`:

```zig
.{
    .name = .my_package,
    .version = "0.1.0",
    .minimum_zig_version = "0.15.2",
    .fingerprint = 0x..........,
    .paths = .{
        "src",
        "build.zig",
        "build.zig.zon",
    },
}
```

Replace the fingerprint placeholder with the fingerprint suggested by `zig build`
for your package name. Include local C headers in `.paths` when using `@cImport`.

> [!IMPORTANT]
> The `paths` field drives **incremental build tracking**. `ZigBuilder` parses
> `build.zig.zon` and registers every file and directory listed in `paths` as a
> build dependency. When any of those files change, Dart's build system
> automatically re-triggers the Zig build. Make sure `paths` includes all source
> directories and files your build depends on (e.g. `"src"`, C headers,
> embedded data files).
>
> The `name` field (`.my_package`) is a comptime enum literal and is ignored.

5. Create `zig/src/lib.zig`:

```zig
export fn add(a: i32, b: i32) i32 {
    return a + b;
}
```

6. Generate Dart bindings in `lib/my_package.dart`:

```bash
dart run native_toolchain_zig:zig bindings --output lib/my_package.dart
```

The generator discovers exported Zig declarations and emits Dart `@Native`
bindings that use the same native asset ID registered by `ZigBuilder`.

During development, regenerate automatically when source files change:

```bash
dart run native_toolchain_zig:zig bindings --output lib/my_package.dart --watch
```

7. Create `bin/main.dart` and call the generated bindings:

```dart
import 'package:my_package/my_package.dart';

void main() {
  print(add(3, 4)); // 7
}
```

Run it with `dart run bin/main.dart`. Dart invokes the build hook to compile and
register the native library before executing the program.

## Binding generation

The generator supports exported functions and globals, `extern` structs and
unions, tagged enums, pointers, arrays, and C callbacks. It follows local Zig
imports and carries source comments into the generated Dart documentation.
Unsupported ABI types produce generation errors.

### C imports

Bindings can also use types from C headers imported through Zig's `@cImport`.
See the **[C imports guide][c_imports]** for setup, header discovery, libc
configuration, cross-compilation, callbacks, ABI limitations, and troubleshooting.
The [cImport example][cimport_example] demonstrates these features together.

### Asset IDs

The generated asset ID must match the build hook. For example,
`lib/src/ffi.g.dart` uses `ZigBuilder(assetName: 'src/ffi.g.dart', zigDir: 'zig')`.
Set `libraryName` if the Zig library name differs from the Dart package name.
Use `--asset-id` to override the generated ID.

### CLI and Dart API

Run `dart run native_toolchain_zig:zig bindings --help` for all CLI options.
C translation options (`--target`, `--sysroot`, and `--[no-]link-libc`) are
explained in the [C imports guide][c_imports].

The public Dart API provides `generateBindings`, `generateBindingsSource`, and
`watchBindings`, configured through `ZigBindingsOptions`.
See the [API documentation][api_docs] for usage and configuration details.

## Examples

| Example | Demonstrates | Run from its example directory |
| --- | --- | --- |
| [bindings](https://github.com/ykmnkmi/native_toolchain_zig.dart/tree/main/example/bindings) | Generated bindings and a Dart counter wrapper. | `dart run bindings:main` |
| [cimport](https://github.com/ykmnkmi/native_toolchain_zig.dart/tree/main/example/cimport) | Nested C headers, structs, unions, arrays, pointers, and callbacks. | `dart run cimport:main` |
| [math](https://github.com/ykmnkmi/native_toolchain_zig.dart/tree/main/example/math) | A native math library with handwritten FFI bindings. | `dart run math:main` |
| [dart_api](https://github.com/ykmnkmi/native_toolchain_zig.dart/tree/main/example/dart_api) | Dart native API initialization and isolate messaging. | `dart run dart_api:main` |

## Development and validation

From the repository root, with the desired Zig version on `PATH`:

```bash
dart pub get
dart analyze --fatal-infos
dart format --output=none --set-exit-if-changed .
dart test
zig test lib/src/zig/dump.zig
```

The Zig test command takes a source file, not a directory. Run `zig build test`
from `example/math/zig` for the math tests, and `zig build` from
`example/dart_api/zig` to build its native library. Run the example commands
above sequentially when validating their build hooks.

CI runs the checks on Zig 0.15.2 and 0.16.0. Its Dart test command is
`dart test -P ci`, which excludes tests tagged `fails-on-ci`; use `dart test`
locally for the unfiltered suite.

## License

MIT License - see [LICENSE](https://github.com/ykmnkmi/native_toolchain_zig.dart/blob/main/LICENSE) for details.

<!-- Badges -->

[pub_badge]: https://img.shields.io/pub/v/native_toolchain_zig
[pub_link]: https://pub.dev/packages/native_toolchain_zig
[dart_ci]: https://github.com/ykmnkmi/native_toolchain_zig.dart/actions/workflows/ci.yaml/badge.svg
[dart_ci_link]: https://github.com/ykmnkmi/native_toolchain_zig.dart/actions
[license_badge]: https://img.shields.io/badge/license-MIT-purple.svg
[license_link]: https://opensource.org/licenses/MIT

<!-- Links -->

[dart_hooks]: https://dart.dev/tools/hooks
[zig_download]: https://ziglang.org/download/

[c_imports]: https://github.com/ykmnkmi/native_toolchain_zig.dart/blob/main/doc/c_imports.md
[cimport_example]: https://github.com/ykmnkmi/native_toolchain_zig.dart/tree/main/example/cimport
[bindings_build]: https://github.com/ykmnkmi/native_toolchain_zig.dart/blob/main/example/bindings/zig/build.zig
[api_docs]: https://pub.dev/documentation/native_toolchain_zig/latest/native_toolchain_zig/
