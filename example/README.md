# Examples

## [`math`][math] — Simple Native Math Library

A minimal example showing how to compile a Zig library and call its exported
functions from Dart via `@Native` FFI bindings.

## [`dart_api`][dart_api] — Dart Native API & Isolate Communication

Demonstrates integrating with `dart_api_dl.h` from Zig to pass messages between
Dart isolates and native code using `Dart_NewNativePort_DL` and `Dart_PostCObject_DL`.

[math]: https://github.com/ykmnkmi/native_toolchain_zig.dart/tree/main/example/math
[dart_api]: https://github.com/ykmnkmi/native_toolchain_zig.dart/tree/main/example/dart_api
