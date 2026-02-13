# zig_tcp

A high-performance TCP socket library for Dart, implemented in C and compiled through Zig's build system. It provides an asynchronous I/O layer that integrates with Dart's native assets system via `@Native` bindings and a dedicated background event loop.

This library is designed as a drop-in replacement for Dart's built-in socket implementation, with an architecture that enables future migration to completion-based I/O backends (io_uring on Linux, IOCP on Windows) while maintaining a stable Dart-facing API.

## Architecture

### Threading Model

The library operates on two threads:

- **Dart thread** — calls the public API functions. Synchronous operations (property queries, socket options) execute inline and return immediately. Asynchronous operations (connect, read, write, accept, close) are queued and return a success/failure code without blocking.

- **Event loop thread** — spawned once during `tcp_init()`, runs continuously until `tcp_destroy()`. It drains the request queue, performs socket I/O, and posts results back to Dart through a native port.

```
┌──────────────┐         ┌──────────────────────────────────────┐
│  Dart side   │         │       Event loop thread              │
│              │         │                                      │
│  tcp_connect ├────────►│  Phase 1: Drain request queue        │
│  tcp_read    │  queue  │  Phase 2: Build fd_sets, select()    │
│  tcp_write   │         │  Phase 3: Retry ready pending ops    │
│  tcp_accept  │         │                                      │
│  tcp_close   │         │  ──► Dart_PostCObject_DL ───────►    │
└──────┬───────┘         └──────────────────────────────────────┘
       │                              │
       │  ◄────── native port ◄───────┘
       ▼
  ReceivePort handler
  (request_id, result, data?)
```

### Event Loop Phases

Each iteration of the event loop performs three phases:

1. **Drain the request queue.** Pops all pending requests submitted by the Dart thread and dispatches them. Operations that complete immediately post their results back to Dart right away.

2. **Build fd_sets and select().** Scans the pending operations array for deferred I/O (operations that returned `EWOULDBLOCK` or `EINPROGRESS`) and registers their file descriptors in the appropriate `fd_set`. Calls `select()` with a short timeout to detect readiness.

3. **Retry ready operations.** Iterates the pending array and retries any operation whose fd became ready. If the retry itself gets `EWOULDBLOCK` again, the operation is re-parked for the next iteration.

### Synchronous vs Asynchronous Split

| Category | Functions | Mechanism |
|---|---|---|
| **Async** | `tcp_connect`, `tcp_read`, `tcp_write`, `tcp_close_write`, `tcp_close`, `tcp_listen`, `tcp_accept`, `tcp_listener_close` | Queued to event loop, result posted via native port |
| **Sync** | `tcp_get_local_address`, `tcp_get_local_port`, `tcp_get_remote_address`, `tcp_get_remote_port`, `tcp_get_keep_alive`, `tcp_set_keep_alive`, `tcp_get_no_delay`, `tcp_set_no_delay` | Direct call with mutex, returns immediately |

> **Note:** The synchronous functions acquire a mutex internally and must not be declared as Dart leaf calls (`isLeaf: true`). All bindings in `ffi.dart` use regular `@Native` without `isLeaf`, which is correct.

## Memory Management

### Read Operations

When a read completes, the event loop allocates a buffer via `malloc()`, fills it with received data, and posts it to Dart as `Dart_CObject_kExternalTypedData`. Dart takes ownership of the buffer. A finalizer callback (`free_finalizer`) is attached so the buffer is freed when Dart's garbage collector collects the typed data object.

```
Event loop                    Dart
─────────                    ────
malloc(65536)
recv(fd, buf, 65536)
realloc(buf, actual_bytes)
                         ──► ExternalTypedData { data: buf, callback: free_finalizer }
                              ... Dart uses the data ...
                              GC collects ──► free_finalizer(buf)
```

### Write Operations

The public `tcp_write()` function copies the caller's buffer immediately via `malloc` + `memcpy`. This is necessary because Dart's GC may relocate or collect the original `Uint8List` buffer while the write is pending on the event loop thread. The copied buffer is freed after the write completes (or on error/cancellation).

Partial writes are handled transparently: if `send()` writes fewer bytes than requested, the remaining data is re-parked as a pending operation. The completion message is only posted to Dart after all bytes have been sent, reporting the total count.

### Socket Table

Socket handles are managed through a fixed-size table (`MAX_SOCKETS = 1024`). Each slot stores the file descriptor, socket type, connection state, and cached local/remote addresses. The table is protected by a mutex for thread-safe access between the Dart thread (sync property calls) and the event loop thread.

## Error Handling

All functions follow a consistent convention:

- **Positive integers** — success values (handles, byte counts, address lengths)
- **Zero** — success with no value
- **Negative integers** — error codes

Error codes are defined in `tcp_socket.h` and mirrored as constants in `ffi.dart`:

| Code | Constant | Meaning |
|------|----------|---------|
| -1 | `TCP_ERR_INVALID_HANDLE` | Handle is invalid or already closed |
| -2 | `TCP_ERR_INVALID_ADDRESS` | Address format is wrong (not 4 or 16 bytes) |
| -3 | `TCP_ERR_CONNECT_FAILED` | Connection attempt failed |
| -4 | `TCP_ERR_BIND_FAILED` | Could not bind to address/port |
| -5 | `TCP_ERR_LISTEN_FAILED` | Listen call failed |
| -6 | `TCP_ERR_ACCEPT_FAILED` | Accept call failed |
| -7 | `TCP_ERR_READ_FAILED` | Read operation failed |
| -8 | `TCP_ERR_WRITE_FAILED` | Write operation failed |
| -9 | `TCP_ERR_CLOSED` | Connection closed by peer (EOF) |
| -10 | `TCP_ERR_SOCKET_OPTION` | `getsockopt`/`setsockopt` failed |
| -11 | `TCP_ERR_NOT_INITIALIZED` | `tcp_init()` has not been called |
| -12 | `TCP_ERR_OUT_OF_MEMORY` | Memory allocation or queue full |
| -13 | `TCP_ERR_INVALID_ARGUMENT` | Invalid parameter (null data, negative count) |

On the Dart side, these map to a sealed error hierarchy for exhaustive pattern matching.

## Dart Native Port Message Format

Async operation results are posted to Dart as a three-element array:

```
[request_id: int64, result: int64, data: ExternalTypedData | null]
```

- `request_id` — correlates the result with the original request
- `result` — positive handle/count on success, negative error code on failure
- `data` — non-null only for successful read operations, containing the received bytes

## Platform Support

The implementation uses portable BSD sockets with platform abstractions for:

| Concern | POSIX | Windows |
|---|---|---|
| Threading | pthreads | `CRITICAL_SECTION` / `CONDITION_VARIABLE` / `CreateThread` |
| Socket type | `int` | `SOCKET` (`UINT_PTR`) |
| Non-blocking | `fcntl(O_NONBLOCK)` | `ioctlsocket(FIONBIO)` |
| Close socket | `close()` | `closesocket()` |
| Shutdown write | `SHUT_WR` | `SD_SEND` |
| Winsock init | N/A | `WSAStartup` / `WSACleanup` |

The `select()`-based event loop serves as a portable baseline. The architecture is designed so that the event loop internals can be swapped for platform-specific backends (io_uring, IOCP) without changing the public API or the Dart integration layer.

## Project Structure

```
lib/
└── src/
    └── ffi.dart               # Dart @Native FFI bindings
zig/
├── build.zig                  # Zig build configuration
├── src/
│   └── lib.zig                # Zig root module (@cImport of the C API)
└── include/
    ├── tcp_socket.h           # Public C API header
    ├── tcp_socket_impl.c      # Full implementation
    ├── dart_api_dl.h          # Dart DL API header (from Dart SDK)
    └── dart_api_dl.c          # Dart DL API implementation (from Dart SDK)
```

## Building

### Prerequisites

- [Zig](https://ziglang.org/download/) 0.15.x

### Build

```sh
cd zig
zig build
```

The output is `zig-out/lib/libzig_tcp.so` (Linux) or `zig-out/lib/zig_tcp.dll` (Windows).

### Verify Exports

Linux:

```sh
nm -D zig-out/lib/libzig_tcp.so | grep tcp_
```

Windows:

```cmd
dumpbin /exports zig-out\lib\zig_tcp.dll
```

All `tcp_*` functions should be visible in the dynamic symbol table.

### Cross-Compilation

Zig supports cross-compilation out of the box:

```sh
# Build for Linux x86_64 from any host
zig build -Dtarget=x86_64-linux-gnu

# Build for Windows x86_64 from any host
zig build -Dtarget=x86_64-windows-gnu
```

## Dart Integration

### FFI Bindings

All native function bindings live in `lib/src/ffi.dart` using Dart's `@Native` annotations. The bindings map directly to the C function signatures with matching types (`Int64` ↔ `int64_t`, `Pointer<Uint8>` ↔ `uint8_t*`, `Bool` ↔ `bool`).

### Receiving Async Results

Async operation results arrive through a `ReceivePort` whose send port is passed to `tcp_init()`:

```dart
import 'dart:ffi';
import 'dart:isolate';
import 'ffi.dart';

final receivePort = ReceivePort();

tcp_init(NativeApi.initializeApiDLData, receivePort.sendPort.nativePort);

receivePort.listen((message) {
  final [requestId as int, result as int, data] = message as List;

  if (result < 0) {
    // Error — match against TCP_ERR_* constants
    handleError(requestId, result);
  } else if (data != null) {
    // Read completed — data is a Uint8List backed by native memory
    handleReadData(requestId, result, data);
  } else {
    // Non-read success — result is a handle or byte count
    handleSuccess(requestId, result);
  }
});
```

### Passing Addresses

Address bytes come from `InternetAddress.rawAddress` and are passed as raw pointers:

```dart
import 'dart:io';
import 'dart:typed_data';

import 'ffi.dart';

final address = InternetAddress('127.0.0.1');
final rawAddr = address.rawAddress; // Uint8List, 4 bytes for IPv4

final result = tcp_connect(
  requestId,
  rawAddr.address.cast<Uint8>(),  // Pointer<Uint8> to address bytes
  rawAddr.length,                  // 4 for IPv4, 16 for IPv6
  8080,                            // port
  nullptr,                         // no source address binding
  0,
  0,
);
```

## Lifecycle

1. Call `tcp_init()` once at startup with the Dart API DL pointer and a send port.
2. Use the async and sync APIs as needed.
3. Call `tcp_destroy()` before isolate shutdown to stop the event loop, close all sockets, and free resources.

## Future Direction

The current `select()`-based event loop is a portable baseline. Planned work includes replacing it with platform-native completion-based backends for improved performance:

- **Linux** — io_uring for zero-copy, completion-based I/O
- **Windows** — IOCP (via NTDLL) for native async I/O

These backends will be implemented in Zig, replacing the C event loop internals while keeping the same exported API surface. The `@cImport` bridge in `lib.zig` enables a gradual migration where individual operations can be moved from C to Zig one at a time.