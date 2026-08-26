## 0.2.0

- Add a Zig source generator that emits Dart `@Native` FFI bindings from
  exported Zig declarations.
- Add a `dart run native_toolchain_zig:zig bindings` CLI with optional watch
  mode.
- Bundle a Zig metadata dumper used by the generator instead of relying on
  Zig's currently unavailable header emission.
- Bump SDK version to 3.13.0.
- Bump dependencies.

## 0.1.1

- Fix `FormatException: Positive input exceeds the limit of integer` when
  parsing `.fingerprint` in `build.zig.zon`.

## 0.1.0

- Initial version.
