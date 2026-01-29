# 🔧 native_toolchain_zig

[![Pub Version][pub_badge]][pub_link]
[![Dart CI][dart_ci]][dart_ci_link]
[![License: MIT][license_badge]][license_link]

Zig support for Dart's [build hooks][dart_hooks].
Automatically builds and bundles your Zig code with your Dart/Flutter application.

### Prerequisites

Install [Zig 0.15.0+][zig_download] on your development machine.

### Installation
```bash
dart pub add hooks native_toolchain_zig
```

### Project Setup

1. Create your Zig project in `zig/`:
```
my_package/
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
            .link_libc = true,
            .pic = true,
        }),
    });

    b.installArtifact(lib);
}
```

<details>
<summary><strong>Build both static and dynamic libraries</strong></summary>

To produce both library types in a single build:

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .pic = true,
    });

    // Dynamic library (.so, .dylib, .dll)
    const dynamic_lib = b.addLibrary(.{
        .name = "my_package",
        .linkage = .dynamic,
        .root_module = root_module,
    });

    b.installArtifact(dynamic_lib);

    // Static library (.a, .lib)
    const static_lib = b.addLibrary(.{
        .name = "my_package",
        .linkage = .static,
        .root_module = root_module,
    });

    b.installArtifact(static_lib);
}
```

</details>

<details>
<summary><strong>Select linkage via command line</strong></summary>

To control linkage type via `-Dlinkage=static` or `-Dlinkage=dynamic`:

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const linkage = b.option(
        std.builtin.LinkMode,
        "linkage",
        "Library linkage type",
    ) orelse .dynamic;

    const lib = b.addLibrary(.{
        .name = "my_package",
        .linkage = linkage,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lib.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .pic = true,
        }),
    });

    b.installArtifact(lib);
}
```

Build with: `zig build -Dlinkage=static` or `zig build -Dlinkage=dynamic`

</details>

4. Create `zig/build.zig.zon`:
```zig
.{
    .name = .my_package,
    .version = "0.1.0",
    .minimum_zig_version = "0.15.0",
    .paths = .{
        "src",
        "build.zig",
        "build.zig.zon",
    },
}
```

5. Create `zig/src/lib.zig`:
```zig
export fn add(a: i32, b: i32) i32 {
    return a + b;
}
```

6. Create Dart bindings in `lib/my_package.dart`:
```dart
import 'dart:ffi';

@Native<Int32 Function(Int32, Int32)>()
external int add(int a, int b);
```

7. Run your app:
```bash
dart run
```

## License

MIT License - see [LICENSE](LICENSE) for details.

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
