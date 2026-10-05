# cImport Stress Example

Demonstrates generating Dart FFI bindings from a Zig source file that uses `@cImport`
with nested headers, structs, unions, enums, callbacks, arrays, and opaque-like
pointer patterns.

See the [C imports guide](../../doc/c_imports.md) for header discovery, libc,
cross-compilation, and limitations.

## Generating Bindings

From the `example/cimport` directory:

```bash
dart run native_toolchain_zig:zig bindings \
  --zig-dir zig \
  --root-source-file src/lib.zig \
  --output lib/ffi.g.dart
```

## Running

```bash
dart run cimport:main
```

## What It Covers

1. `@cImport` of multiple local headers.
2. Struct, union, enum, and function pointer translation.
3. Arrays, nested records, pointer chains, and callback plumbing.
4. Generated Dart bindings plus a small wrapper around the raw FFI surface.
