## 0.3.0

### Breaking changes

Generated bindings can differ from 0.2.x in type selection, callback signatures,
and array layouts. Packed structs and ambiguous type matches now fail generation.

### Changes

- Prefer exact ABI type names and reject ambiguous suffix matches.
- Reject Zig packed structs rather than emit incompatible Dart layouts.
- Include sentinel storage in array dimensions, including nested arrays.
- Translate multiple C includes on the same source line correctly.
- Prevent generated files and nested Zig caches from retriggering watch mode.
- Detect libc header support for C imports with a Zig comptime check using the
  selected build module's configuration, with CLI and Dart API overrides.
- Stop tracking generated `.zigchain_cimport` intermediate files.
- Add `@cImport` bindings support, including local header discovery and resolution
  of translated C types used by exported Zig declarations.
- Add `--target` and `--sysroot` CLI options and matching `ZigBindingsOptions`
  fields for target-specific C translation.
- Support C function pointer callbacks, including callbacks returning `void`.
- Fix fixed-size array field emission and support multidimensional arrays.
- Reject unsupported callback calling conventions and packed struct bit layouts
  with explicit errors.
- Add the cImport stress example covering nested headers, structs, unions,
  arrays, pointer chains, and callable/listener callbacks.
- Split the Dart generator and Zig extractor into focused modules and expand
  generator API documentation.
- Make the Zig test fixtures compatible with Zig 0.15 and 0.16, and run CI on
  Zig 0.15.2 and 0.16.0.

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
