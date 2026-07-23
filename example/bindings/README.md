# Bindings Example

Demonstrates generating Dart FFI bindings from Zig source code using the
`bindings` CLI command. The generated file provides typed structs and function
bindings — no hand-written `@Native` annotations needed.

## Prerequisites

- Dart SDK ^3.11.0
- Zig 0.15.x installed and available on `PATH`

## Generating Bindings

From the `example/bindings` directory:

```bash
dart run native_toolchain_zig:zig bindings \
  --zig-dir zig \
  --root-source-file src/counter.zig \
  --output lib/ffi.g.dart
```

Or from the repository root:

```bash
dart run native_toolchain_zig:zig bindings \
  --package-root example/bindings \
  --zig-dir zig \
  --root-source-file src/counter.zig \
  --output lib/ffi.g.dart
```

Use `--watch` to regenerate automatically when Zig source files change:

```bash
dart run native_toolchain_zig:zig bindings \
  --zig-dir zig \
  --root-source-file src/counter.zig \
  --output lib/ffi.g.dart \
  --watch
```

## Running

```bash
dart run bindings:main
```

## How It Works

1. `zig/src/counter.zig` defines exported functions (`export fn`) and an
   `extern struct` (`Counter`).
2. The `bindings` CLI runs `zig translate-c` under the hood to extract the
   exported ABI surface, then generates `lib/ffi.g.dart`.
3. `lib/bindings.dart` wraps the raw FFI calls in a Dart-friendly
   `CounterWrapper` class.
4. The build hook (`hook/build.dart`) compiles the Zig code into a native
   library and registers it as a code asset.
5. `bin/main.dart` calls both the raw bindings and the wrapper to demonstrate
   usage.
