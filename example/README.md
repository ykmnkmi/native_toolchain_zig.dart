# Examples

## [`zig_math`][zig_math] — Simple Native Math Library

A minimal example showing how to compile a Zig library and call its exported
functions from Dart via `@Native` FFI bindings.

## [`zig_dart_api`][zig_dart_api] — Dart Native API & Isolate Communication

Demonstrates integrating with `dart_api_dl.h` from Zig to pass messages between
Dart isolates and native code using `Dart_NewNativePort_DL` and `Dart_PostCObject_DL`.

## [`zig_tcp`][zig_tcp] — Cross-Platform Async TCP Sockets

A full async TCP socket library with a Dart `Connection`/`Listener` API backed
by platform-native I/O (IOCP on Windows, `io_uring` on Linux, `libxev` elsewhere),
multi-isolate support, and GC-safe handle lifecycle management.

[zig_math]: https://github.com/ykmnkmi/native_toolchain_zig.dart/tree/main/example/zig_math
[zig_dart_api]: https://github.com/ykmnkmi/native_toolchain_zig.dart/tree/main/example/zig_dart_api
[zig_tcp]: https://github.com/ykmnkmi/native_toolchain_zig.dart/tree/main/example/zig_tcp