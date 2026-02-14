<!-- README.md -->

# zig_tcp

A cross-platform TCP socket library for Dart, implemented in C and compiled
through Zig's build system. It provides asynchronous I/O via a dedicated
background event loop that posts results to Dart through native ports, with
support for multiple concurrent isolates.

## Architecture

The library spawns a single background event loop thread on `tcp_init()`. Dart
threads queue async operations (connect, read, write, accept, close) which
return immediately. The event loop processes them using non-blocking sockets and
`select()`, posting results back to Dart via `Dart_PostCObject_DL`.

Synchronous property accessors (address, port, keep-alive, no-delay) execute
inline under a mutex and return immediately. They must not be used as Dart leaf
calls (`isLeaf: true`) since the mutex can block.

```
Dart threads              Event loop thread
───────────              ─────────────────
tcp_connect ──► queue ──► dispatch → select → retry → post_result ──► ReceivePort
tcp_listen  ──►       ──►
tcp_read    ──►       ──►
```

## Multi-Isolate Support

Handle-creating operations (`tcp_connect`, `tcp_listen`) take a `send_port`
parameter - the calling isolate's `receivePort.sendPort.nativePort`. This port
is stored on the socket handle, and all subsequent operations on that handle
(read, write, close) route results to the correct isolate automatically.
Accepted connections inherit the listener's port.

For `shared: true` listeners, each isolate creates its own listener bound to the
same address via `SO_REUSEADDR`/`SO_REUSEPORT`. The kernel distributes incoming
connections across them, and each isolate's accept results go to its own port.

## Memory Management

Read buffers are `malloc`'d by the event loop and transferred to Dart as
`ExternalTypedData` with a `free_finalizer` callback - Dart's GC frees them
automatically. Write data is copied immediately in `tcp_write()` since Dart's GC
may relocate the original buffer while the write is pending. Partial writes are
handled transparently by re-parking the remaining data until the socket is
writable again.

## Error Handling

All functions return positive integers for success (handles, byte counts) or
zero, and negative integers for errors. Error codes are defined in `tcp.h` and
mirrored as constants in `ffi.dart` (`TCP_ERR_CONNECT_FAILED`, `TCP_ERR_CLOSED`,
etc.).

## Project Structure

```
lib/src/ffi.dart                Dart @Native FFI bindings
zig/build.zig                   Zig build configuration
zig/src/lib.zig                 Zig root module (@cImport bridge)
zig/include/tcp.h               Public C API header
zig/include/tcp.c               Implementation
zig/include/dart_api_dl.{h,c}   Dart DL API (from Dart SDK)
```

## Building

Requires [Zig](https://ziglang.org/download/) 0.15.x.

```sh
cd zig
zig build
# Output: zig-out/lib/libzig_tcp.so (Linux) or zig_tcp.dll (Windows)

# Cross-compile:
zig build -Dtarget=x86_64-linux-gnu
zig build -Dtarget=x86_64-windows-gnu
```

## Dart Integration

```dart
import 'dart:ffi';
import 'dart:isolate';

// Initialize once (idempotent, safe from any isolate)
tcp_init(NativeApi.initializeApiDLData);

// Each isolate creates its own ReceivePort
final receivePort = ReceivePort();
final nativePort = receivePort.sendPort.nativePort;

// Pass nativePort to handle-creating operations
tcp_connect(nativePort, requestId, addr, addrLen, 8080, nullptr, 0, 0);
tcp_listen(nativePort, requestId, addr, addrLen, 8080, false, 0, true);

// Handle operations derive the port from the handle - no port needed
tcp_read(requestId, handle);
tcp_write(requestId, handle, data, 0, length);

// Results arrive as [requestId, result, data?]
receivePort.listen((List<Object?> message) {
  final [requestId as int, result as int, data as Uint8List?] = message;
  // result > 0: handle or byte count
  // result < 0: error code (TCP_ERR_*)
  // data != null: read completed (Uint8List)
});
```

## Future Direction

The `select()`-based event loop is a portable baseline. Planned backends include
io_uring (Linux) and IOCP (Windows), implemented in Zig behind the same exported
C API.
