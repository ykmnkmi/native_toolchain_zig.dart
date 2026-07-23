# Examples

## [`bindings`][bindings] — Generated FFI Bindings

Shows how to use the `bindings` CLI to generate Dart FFI bindings from Zig source
automatically. The generated file provides typed structs and function bindings
with no hand-written `@Native` annotations.

## [`math`][math] — Simple Native Math Library

A minimal example showing how to compile a Zig library and call its exported
functions from Dart via `@Native` FFI bindings.

## [`dart_api`][dart_api] — Dart Native API & Isolate Communication

Demonstrates integrating with `dart_api_dl.h` from Zig to pass messages between
Dart isolates and native code using `Dart_NewNativePort_DL` and `Dart_PostCObject_DL`.

[bindings]: https://github.com/ykmnkmi/native_toolchain_zig.dart/tree/main/example/bindings
[math]: https://github.com/ykmnkmi/native_toolchain_zig.dart/tree/main/example/math
[dart_api]: https://github.com/ykmnkmi/native_toolchain_zig.dart/tree/main/example/dart_api
